using System;
using UnityEngine;

namespace KPK.CodexUnityLink.Editor
{
    [Serializable]
    internal sealed class UnityAssetLinkRequest
    {
        public int version;
        public string requestId;
        public string action;
        public string projectRoot;
        public string assetPath;
        public int line;
        public int column;
    }

    [Serializable]
    internal sealed class UnityAssetLinkResponse
    {
        public int version;
        public string requestId;
        public bool ok;
        public string code;
        public string message;
    }

    internal static class UnityAssetLinkProtocol
    {
        internal const int Version = 1;
        internal const int MaxMessageChars = 65536;

        internal static bool TryParse(
            string json,
            out UnityAssetLinkRequest request,
            out UnityAssetLinkResponse error)
        {
            request = null;
            error = null;
            if (string.IsNullOrEmpty(json) || json.Length > MaxMessageChars)
            {
                error = Failure(null, "invalidRequest", "Request is empty or too large.");
                return false;
            }

            try
            {
                request = JsonUtility.FromJson<UnityAssetLinkRequest>(json);
            }
            catch (Exception)
            {
                error = Failure(null, "invalidRequest", "Request JSON is invalid.");
                return false;
            }

            if (request == null
                || request.version != Version
                || request.action != "openAsset"
                || string.IsNullOrEmpty(request.requestId)
                || string.IsNullOrEmpty(request.projectRoot)
                || string.IsNullOrEmpty(request.assetPath))
            {
                error = Failure(
                    request != null ? request.requestId : null,
                    "invalidRequest",
                    "Request version, id, or action is invalid.");
                return false;
            }
            return true;
        }

        internal static UnityAssetLinkResponse Success(string requestId)
        {
            return new UnityAssetLinkResponse
            {
                version = Version,
                requestId = requestId,
                ok = true,
                code = "opened",
                message = string.Empty
            };
        }

        internal static UnityAssetLinkResponse Failure(string requestId, string code, string message)
        {
            return new UnityAssetLinkResponse
            {
                version = Version,
                requestId = requestId ?? string.Empty,
                ok = false,
                code = code,
                message = message
            };
        }

        internal static string Serialize(UnityAssetLinkResponse response)
        {
            return JsonUtility.ToJson(response);
        }
    }
}
