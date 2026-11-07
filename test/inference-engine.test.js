const test = require("node:test");
const assert = require("node:assert/strict");

const { createInferenceEngine } = require("../prototype/js/inference-engine.js");

const asset = {
  id: "test-model",
  tier: "mainstream",
  version: "1.0.0",
  sha256: "a".repeat(64),
  sizeBytes: 1,
  capabilities: ["chat", "voice"],
};

test("engine loads an asset and streams deterministic output", async () => {
  const engine = createInferenceEngine({
    buildReply: ({ mode, message }) => `mode=${mode}: ${message}`,
    latencyProfile: { chat: 500 },
  });
  engine.load(asset);

  const result = await engine.generate({ mode: "chat", prompt: "你好" });
  assert.equal(result.text, "mode=chat: 你好");
  assert.equal(result.metrics.cancelled, false);
  assert.equal(result.metrics.plannedFirstTokenMs, 500);
  assert.ok(result.metrics.outputChars > 0);
});

test("engine rejects unsupported modes and missing prompts", async () => {
  const engine = createInferenceEngine();
  engine.load(asset);

  await assert.rejects(
    () => engine.generate({ mode: "video", prompt: "看画面" }),
    /does not support video/
  );
  await assert.rejects(
    () => engine.generate({ mode: "chat", prompt: "" }),
    /prompt is required/
  );
});

test("engine fails generation before a model is loaded", async () => {
  const engine = createInferenceEngine();
  await assert.rejects(
    () => engine.generate({ mode: "chat", prompt: "hello" }),
    /not ready/
  );
});

test("engine supports cancellation during streaming", async () => {
  const controller = new AbortController();
  const engine = createInferenceEngine({
    buildReply: () => "这是一段足够长的输出，用于验证取消能力。",
    delay: async () => {
      controller.abort();
    },
  });
  engine.load(asset);

  await assert.rejects(
    async () => {
      for await (const event of engine.generateStream({
        mode: "chat",
        prompt: "测试",
        signal: controller.signal,
      })) {
        // Drain until abort happens.
      }
    },
    (error) => error.name === "AbortError"
  );

  assert.equal(engine.status().lastMetrics.cancelled, true);
});

test("engine can unload and return to a clean state", async () => {
  const engine = createInferenceEngine();
  engine.load(asset);
  assert.equal(engine.status().state, "ready");
  engine.unload();
  assert.equal(engine.status().state, "unloaded");
  assert.equal(engine.status().asset, null);
});

