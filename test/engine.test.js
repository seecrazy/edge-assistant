const test = require("node:test");
const assert = require("node:assert/strict");

const {
  classifyDevice,
  planPipeline,
  conversationTransition,
  interruptAction,
  chooseReply,
  privacyAudit,
} = require("../prototype/js/engine.js");

test("classifies flagship devices only with NPU and enough RAM", () => {
  assert.equal(classifyDevice({ ramGb: 12, hasNpu: true }).tier, "flagship");
  assert.equal(classifyDevice({ ramGb: 16, hasNpu: false }).tier, "mainstream");
  assert.equal(classifyDevice({ ramGb: 8, hasNpu: false }).tier, "mainstream");
  assert.equal(classifyDevice({ ramGb: 6, hasNpu: true }).tier, "entry");
});

test("rejects invalid device input", () => {
  assert.throws(() => classifyDevice({ ramGb: 0, hasNpu: true }), /positive number/);
  assert.throws(() => classifyDevice(null), /positive number/);
});

test("voice pipeline meets the latency target for supported tiers", () => {
  ["flagship", "mainstream", "entry"].forEach((tier) => {
    const plan = planPipeline({ mode: "voice", tier });
    assert.equal(plan.mode, "voice");
    assert.ok(plan.totalMs > 0);
    assert.ok(plan.meetsTarget, `${tier} should stay within 1200ms`);
  });
});

test("video is slower and may require degradation", () => {
  const flagship = planPipeline({ mode: "video", tier: "flagship" });
  const entry = planPipeline({ mode: "video", tier: "entry" });
  assert.equal(flagship.meetsTarget, true);
  assert.equal(entry.meetsTarget, false);
});

test("rejects unknown modes and tiers", () => {
  assert.throws(() => planPipeline({ mode: "phone", tier: "flagship" }), /mode/);
  assert.throws(() => planPipeline({ mode: "chat", tier: "unknown" }), /tier/);
});

test("conversation transitions follow the voice state machine", () => {
  assert.equal(conversationTransition("idle", "start_call"), "listening");
  assert.equal(conversationTransition("listening", "user_stop"), "thinking");
  assert.equal(conversationTransition("thinking", "first_token"), "speaking");
  assert.equal(conversationTransition("speaking", "tts_done"), "listening");
  assert.equal(conversationTransition("speaking", "interrupt"), "listening");
  assert.equal(conversationTransition("idle", "first_token"), null);
});

test("interrupt action cleans up the right resources", () => {
  assert.deepEqual(interruptAction("speaking"), {
    stopTts: true,
    dropQueuedAudio: true,
    cancelInference: true,
    nextState: "listening",
  });
  assert.deepEqual(interruptAction("thinking"), {
    stopTts: false,
    dropQueuedAudio: false,
    cancelInference: true,
    nextState: "listening",
  });
});

test("chooseReply stays deterministic and mode-aware", () => {
  assert.match(chooseReply({ mode: "voice", message: "帮我设提醒" }), /提醒/);
  assert.match(chooseReply({ mode: "video", message: "你看到了什么" }), /画面摘要/);
  assert.match(chooseReply({ mode: "chat", message: "你好" }), /模拟回复/);
});

test("privacy audit flags any network request", () => {
  const localOnly = privacyAudit([
    { type: "asr" },
    { type: "llm" },
    { type: "tts" },
  ]);
  assert.equal(localOnly.localOnly, true);
  assert.equal(localOnly.networkRequests, 0);

  const withNetwork = privacyAudit([
    { type: "asr" },
    { type: "network_request" },
  ]);
  assert.equal(withNetwork.localOnly, false);
  assert.equal(withNetwork.networkRequests, 1);
});

