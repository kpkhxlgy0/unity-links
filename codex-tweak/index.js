const PIPE_PREFIX = "kpk-codex-unity-link-v1-";
let rendererCleanup;

function parseDestination(raw) {
  if (typeof raw !== "string" || raw.trim() === "") return null;
  let value = raw.trim();
  if (/^(https?|mailto):/i.test(value)) return null;

  if (/^file:/i.test(value)) {
    try {
      const url = new URL(value);
      if (url.protocol !== "file:" || (url.hostname && url.hostname !== "localhost")) {
        return null;
      }
      value = decodeURIComponent(url.pathname);
    } catch {
      return null;
    }
  } else {
    try {
      value = decodeURIComponent(value);
    } catch {
      return null;
    }
  }

  value = value.replace(/^\/([A-Za-z]:[\\/])/, "$1");
  const parsed = splitLineColumn(value);
  if (!/^[A-Za-z]:[\\/]/.test(parsed.path)) return null;
  return {
    path: parsed.path.replace(/\//g, "\\"),
    line: parsed.line,
    column: parsed.column,
  };
}

function splitLineColumn(value) {
  let match = /^(.*):(\d+):(\d+)$/.exec(value);
  if (match) {
    return {
      path: match[1],
      line: Number(match[2]),
      column: Number(match[3]),
    };
  }
  match = /^(.*):(\d+)$/.exec(value);
  if (match) {
    return { path: match[1], line: Number(match[2]), column: 0 };
  }
  return { path: value, line: 0, column: 0 };
}

function hasAssetsSegment(filePath) {
  return /[\\/]Assets[\\/]/i.test(filePath);
}

function isEligibleClick(event) {
  return event.button === 0
    && !event.defaultPrevented
    && !event.altKey
    && !event.ctrlKey
    && !event.metaKey
    && !event.shiftKey;
}

function normalizeProjectRoot(projectRoot, pathApi) {
  const resolved = pathApi.resolve(projectRoot).replace(/\//g, "\\");
  return resolved.replace(/[\\]+$/, "").toLowerCase();
}

function pipeNameForProjectRoot(projectRoot, cryptoApi, pathApi) {
  const normalized = normalizeProjectRoot(projectRoot, pathApi);
  const digest = cryptoApi.createHash("sha256").update(normalized, "utf8").digest("hex");
  return PIPE_PREFIX + digest;
}

function start(api) {
  if (api.process === "renderer") return;
}

function stop() {
  if (rendererCleanup) {
    rendererCleanup();
    rendererCleanup = undefined;
  }
}

module.exports = {
  start,
  stop,
  __test: {
    parseDestination,
    splitLineColumn,
    hasAssetsSegment,
    isEligibleClick,
    normalizeProjectRoot,
    pipeNameForProjectRoot,
  },
};
