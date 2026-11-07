(function (root, factory) {
  if (typeof module === "object" && module.exports) {
    module.exports = factory();
  } else {
    root.EdgeAssistantInferenceEngine = factory();
  }
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  const MODES = Object.freeze(["chat", "voice", "video"]);

  function abortError() {
    const error = new Error("inference aborted");
    error.name = "AbortError";
    return error;
  }

  function chunkText(text, chunkSize) {
    const chunks = [];
    for (let index = 0; index < text.length; index += chunkSize) {
      chunks.push(text.slice(index, index + chunkSize));
    }
    return chunks;
  }

  function defaultBuildReply(input) {
    const mode = input.mode || "chat";
    const prompt = String(input.prompt || input.message || "").trim();
    if (!prompt) {
      return "请输入内容。";
    }
    return `本地模拟推理完成：${prompt}`;
  }

  function createInferenceEngine(options = {}) {
    const buildReply = options.buildReply || defaultBuildReply;
    const now = options.now || (() => Date.now());
    const delay = options.delay || (() => Promise.resolve());
    const latencyProfile = options.latencyProfile || {};

    let activeAsset = options.asset || null;
    let engineState = activeAsset ? "ready" : "unloaded";
    let lastMetrics = null;
    let lastError = null;

    function assertReady(mode) {
      if (engineState !== "ready" || !activeAsset) {
        throw new Error("inference engine is not ready");
      }
      if (!MODES.includes(mode)) {
        throw new Error("mode must be chat, voice, or video");
      }
      if (!activeAsset.capabilities.includes(mode)) {
        throw new Error(`model does not support ${mode}`);
      }
    }

    function load(asset) {
      if (!asset || typeof asset !== "object") {
        throw new Error("asset is required");
      }
      if (!Array.isArray(asset.capabilities) || asset.capabilities.length === 0) {
        throw new Error("asset capabilities are required");
      }

      activeAsset = { ...asset, capabilities: [...asset.capabilities] };
      engineState = "ready";
      lastError = null;
      return status();
    }

    function unload() {
      activeAsset = null;
      engineState = "unloaded";
      return status();
    }

    function status() {
      return {
        state: engineState,
        asset: activeAsset
          ? { ...activeAsset, capabilities: [...activeAsset.capabilities] }
          : null,
        lastMetrics,
        lastError,
      };
    }

    async function* generateStream(input = {}) {
      const mode = input.mode || "chat";
      assertReady(mode);

      const prompt = String(input.prompt || input.message || "").trim();
      if (!prompt) {
        throw new Error("prompt is required");
      }
      const signal = input.signal;
      if (signal && signal.aborted) {
        throw abortError();
      }

      const maxOutputChars =
        typeof input.maxOutputChars === "number" && input.maxOutputChars > 0
          ? input.maxOutputChars
          : mode === "voice"
            ? 48
            : mode === "video"
              ? 120
              : 180;
      const startedAt = now();
      const reply = buildReply({ mode, message: prompt, prompt });
      const chunks = chunkText(reply.slice(0, maxOutputChars), mode === "voice" ? 2 : 3);

      let firstTokenAt = null;
      let outputChars = 0;

      for (const chunk of chunks) {
        await delay({ mode, first: firstTokenAt === null });
        if (signal && signal.aborted) {
          lastMetrics = {
            mode,
            cancelled: true,
            firstTokenMs: firstTokenAt === null ? null : firstTokenAt - startedAt,
            durationMs: now() - startedAt,
            outputChars,
          };
          throw abortError();
        }

        if (firstTokenAt === null) {
          firstTokenAt = now();
        }
        outputChars += chunk.length;
        yield {
          type: "token",
          text: chunk,
          metrics: {
            firstTokenMs: firstTokenAt - startedAt,
            outputChars,
          },
        };
      }

      const durationMs = now() - startedAt;
      lastMetrics = {
        mode,
        cancelled: false,
        firstTokenMs: firstTokenAt === null ? 0 : firstTokenAt - startedAt,
        durationMs,
        outputChars,
        plannedFirstTokenMs:
          (typeof latencyProfile === "function"
            ? latencyProfile(mode)
            : latencyProfile[mode]) || null,
      };
      lastError = null;
      yield {
        type: "done",
        metrics: lastMetrics,
      };
    }

    async function generate(input = {}) {
      let text = "";
      let metrics = null;
      for await (const event of generateStream(input)) {
        if (event.type === "token") {
          text += event.text;
        } else if (event.type === "done") {
          metrics = event.metrics;
        }
      }
      return { text, metrics };
    }

    return {
      load,
      unload,
      status,
      generate,
      generateStream,
    };
  }

  return {
    createInferenceEngine,
    defaultBuildReply,
  };
});

