using System;
using System.Collections.Concurrent;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using UnityEditor;
using UnityEngine;

namespace KPK.CodexUnityLink.Editor
{
    [InitializeOnLoad]
    internal static class UnityAssetLinkReceiver
    {
        private sealed class PendingRequest
        {
            internal string json;
            internal TaskCompletionSource<string> completion;
        }

        private static readonly ConcurrentQueue<PendingRequest> PendingRequests = new();
        private static readonly ConcurrentQueue<string> PendingErrors = new();
        private static readonly object PipeGate = new();
        private static CancellationTokenSource cancellation;
        private static NamedPipeServerStream activePipe;
        private static string projectRoot;

        static UnityAssetLinkReceiver()
        {
            projectRoot = Directory.GetParent(Application.dataPath).FullName;
            EditorApplication.update += ProcessPendingRequests;
            AssemblyReloadEvents.beforeAssemblyReload += Stop;
            EditorApplication.quitting += Stop;
            Start();
            Debug.Log($"[CodexUnityLink] Listening for project: {projectRoot}");
        }

        private static void Start()
        {
            cancellation = new CancellationTokenSource();
            var pipeName = UnityAssetLinkPath.GetPipeName(projectRoot);
            _ = Task.Run(() => ListenAsync(pipeName, cancellation.Token));
        }

        private static void Stop()
        {
            if (cancellation == null) return;
            cancellation.Cancel();
            lock (PipeGate)
            {
                if (activePipe != null)
                {
                    activePipe.Dispose();
                    activePipe = null;
                }
            }
            cancellation.Dispose();
            cancellation = null;
            while (PendingRequests.TryDequeue(out var pending))
            {
                pending.completion.TrySetCanceled();
            }
            while (PendingErrors.TryDequeue(out _))
            {
            }
        }

        private static async Task ListenAsync(string pipeName, CancellationToken token)
        {
            while (!token.IsCancellationRequested)
            {
                try
                {
                    using (var pipe = new NamedPipeServerStream(
                               pipeName,
                               PipeDirection.InOut,
                               1,
                               PipeTransmissionMode.Byte,
                               PipeOptions.Asynchronous))
                    {
                        lock (PipeGate)
                        {
                            activePipe = pipe;
                        }
                        while (!token.IsCancellationRequested)
                        {
                            await pipe.WaitForConnectionAsync(token);
                            try
                            {
                                await ServeAsync(pipe, token);
                            }
                            finally
                            {
                                if (pipe.IsConnected)
                                    pipe.Disconnect();
                            }
                        }
                    }
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                catch (ObjectDisposedException)
                {
                    if (token.IsCancellationRequested) return;
                    if (!await DelayRetryAsync(token)) return;
                }
                catch (IOException)
                {
                    if (token.IsCancellationRequested) return;
                    if (!await DelayRetryAsync(token)) return;
                }
                catch (Exception exception)
                {
                    PendingErrors.Enqueue(exception.Message);
                    if (!await DelayRetryAsync(token)) return;
                }
                finally
                {
                    lock (PipeGate)
                    {
                        activePipe = null;
                    }
                }
            }
        }

        private static async Task<bool> DelayRetryAsync(CancellationToken token)
        {
            try
            {
                await Task.Delay(1000, token);
                return true;
            }
            catch (OperationCanceledException)
            {
                return false;
            }
        }

        private static async Task ServeAsync(Stream stream, CancellationToken token)
        {
            using (var reader = new StreamReader(stream, Encoding.UTF8, false, 4096, true))
            using (var writer = new StreamWriter(
                       stream,
                       new UTF8Encoding(false),
                       4096,
                       true) { AutoFlush = true })
            {
                var json = await reader.ReadLineAsync();
                if (json == null) return;
                var completion = new TaskCompletionSource<string>(
                    TaskCreationOptions.RunContinuationsAsynchronously);
                PendingRequests.Enqueue(new PendingRequest
                {
                    json = json,
                    completion = completion
                });
                using (token.Register(() => completion.TrySetCanceled()))
                {
                    var response = await completion.Task;
                    await writer.WriteLineAsync(response);
                }
            }
        }

        private static void ProcessPendingRequests()
        {
            while (PendingErrors.TryDequeue(out var message))
            {
                Debug.LogError($"[CodexUnityLink] Pipe listener failed: {message}");
            }
            while (PendingRequests.TryDequeue(out var pending))
            {
                try
                {
                    pending.completion.TrySetResult(ProcessRequest(pending.json));
                }
                catch (Exception exception)
                {
                    var response = UnityAssetLinkProtocol.Failure(
                        null,
                        "openFailed",
                        exception.Message);
                    pending.completion.TrySetResult(SerializeFailure(response));
                }
            }
        }

        private static string ProcessRequest(string json)
        {
            if (!UnityAssetLinkProtocol.TryParse(json, out var request, out var error))
                return SerializeFailure(error);
            if (!UnityAssetLinkPath.TryResolveAsset(projectRoot, request, out var assetPath, out error))
                return SerializeFailure(error);

            var asset = AssetDatabase.LoadAssetAtPath<UnityEngine.Object>(assetPath);
            if (asset == null)
            {
                error = UnityAssetLinkProtocol.Failure(
                    request.requestId,
                    "assetMissing",
                    "Unity could not load the requested asset.");
                return SerializeFailure(error);
            }

            bool opened;
            if (request.line <= 0)
                opened = AssetDatabase.OpenAsset(asset);
            else if (request.column <= 0)
                opened = AssetDatabase.OpenAsset(asset, request.line);
            else
                opened = AssetDatabase.OpenAsset(asset, request.line, request.column);

            if (!opened)
            {
                error = UnityAssetLinkProtocol.Failure(
                    request.requestId,
                    "openFailed",
                    "Unity did not accept the asset open request.");
                return SerializeFailure(error);
            }
            return UnityAssetLinkProtocol.Serialize(
                UnityAssetLinkProtocol.Success(request.requestId));
        }

        private static string SerializeFailure(UnityAssetLinkResponse response)
        {
            Debug.LogWarning($"[CodexUnityLink] {response.code}: {response.message}");
            return UnityAssetLinkProtocol.Serialize(response);
        }
    }
}
