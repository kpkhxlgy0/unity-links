using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace KPK.CodexUnityLink.Editor
{
    internal static class UnityAssetLinkPath
    {
        private const string PipePrefix = "kpk-codex-unity-link-v1-";

        internal static string NormalizeProjectRoot(string projectRoot)
        {
            return Path.GetFullPath(projectRoot)
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
                .Replace('/', '\\')
                .ToLowerInvariant();
        }

        internal static string GetPipeName(string projectRoot)
        {
            var normalized = NormalizeProjectRoot(projectRoot);
            using (var sha = SHA256.Create())
            {
                var bytes = sha.ComputeHash(Encoding.UTF8.GetBytes(normalized));
                var digest = BitConverter.ToString(bytes).Replace("-", string.Empty).ToLowerInvariant();
                return PipePrefix + digest;
            }
        }

        internal static bool TryResolveAsset(
            string currentProjectRoot,
            UnityAssetLinkRequest request,
            out string assetPath,
            out UnityAssetLinkResponse error)
        {
            assetPath = null;
            error = null;
            if (!string.Equals(
                    NormalizeProjectRoot(currentProjectRoot),
                    NormalizeProjectRoot(request.projectRoot),
                    StringComparison.OrdinalIgnoreCase))
            {
                error = UnityAssetLinkProtocol.Failure(
                    request.requestId,
                    "wrongProject",
                    "The request belongs to another Unity project.");
                return false;
            }

            var normalizedAssetPath = (request.assetPath ?? string.Empty).Replace('\\', '/');
            var segments = normalizedAssetPath.Split('/');
            var supportedRootName = segments.Length > 0
                && (segments[0] == "Assets"
                    || segments[0] == "ProjectSettings"
                    || segments[0] == "Packages")
                    ? segments[0]
                    : null;
            if (segments.Length < 2
                || supportedRootName == null
                || Array.Exists(
                    segments,
                    segment => string.IsNullOrEmpty(segment) || segment == ".." || segment == "."))
            {
                error = UnityAssetLinkProtocol.Failure(
                    request.requestId,
                    "assetOutsideProject",
                    "The requested path is outside this project's supported Unity directories.");
                return false;
            }

            var supportedRoot = Path.Combine(currentProjectRoot, supportedRootName);
            if ((File.GetAttributes(supportedRoot) & FileAttributes.ReparsePoint) != 0)
            {
                error = UnityAssetLinkProtocol.Failure(
                    request.requestId,
                    "assetOutsideProject",
                    $"A reparse-point {supportedRootName} directory is not accepted.");
                return false;
            }
            var absolute = Path.GetFullPath(
                Path.Combine(currentProjectRoot, normalizedAssetPath.Replace('/', Path.DirectorySeparatorChar)));
            var supportedPrefix = supportedRoot.TrimEnd(Path.DirectorySeparatorChar)
                                  + Path.DirectorySeparatorChar;
            if (!absolute.StartsWith(supportedPrefix, StringComparison.OrdinalIgnoreCase))
            {
                error = UnityAssetLinkProtocol.Failure(
                    request.requestId,
                    "assetOutsideProject",
                    $"The requested path escapes this project's {supportedRootName} directory.");
                return false;
            }

            var current = supportedRoot;
            for (var i = 1; i < segments.Length; i++)
            {
                current = Path.Combine(current, segments[i]);
                if (!File.Exists(current) && !Directory.Exists(current))
                {
                    error = UnityAssetLinkProtocol.Failure(
                        request.requestId,
                        "assetMissing",
                        "The requested Unity asset does not exist.");
                    return false;
                }
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                {
                    error = UnityAssetLinkProtocol.Failure(
                        request.requestId,
                        "assetOutsideProject",
                        "Reparse-point asset paths are not accepted.");
                    return false;
                }
            }

            if (!File.Exists(absolute))
            {
                error = UnityAssetLinkProtocol.Failure(
                    request.requestId,
                    "assetMissing",
                    "The requested Unity asset is not a file.");
                return false;
            }
            assetPath = normalizedAssetPath;
            return true;
        }
    }
}
