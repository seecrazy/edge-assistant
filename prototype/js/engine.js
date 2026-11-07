(function (root, factory) {
  if (typeof module === "object" && module.exports) {
    module.exports = factory();
  } else {
    root.EdgeAssistant = factory();
  }
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  const MODEL_TIERS = Object.freeze({
    flagship: {
      tier: "flagship",
      label: "Flagship",
      model: "3–4B dense / MoE, 4-bit",
      assetSizeGb: "2.0–2.5GB",
      modes: ["chat", "voice", "video"],
      description: "完整语音通话与视频理解",
    },
    mainstream: {
      tier: "mainstream",
      label: "Mainstream",
      model: "1.5–2B dense, 4-bit",
      assetSizeGb: "1.0–1.5GB",
      modes: ["chat", "voice", "video"],
      description: "语音通话与基础视觉摘要",
    },
    entry: {
      tier: "entry",
      label: "Entry",
      model: "1B dense, 4-bit",
      assetSizeGb: "0.7–0.9GB",
      modes: ["chat", "voice"],
      description: "文字与短句语音；视频功能默认禁用",
    },
  });

  function classifyDevice(input) {
    const ramGb = Number(input && input.ramGb);
    const hasNpu = Boolean(input && input.hasNpu);

    if (!Number.isFinite(ramGb) || ramGb <= 0) {
      throw new Error("ramGb must be a positive number");
    }

    if (ramGb >= 12 && hasNpu) {
      return { ...MODEL_TIERS.flagship };
    }
    if (ramGb >= 8) {
      return { ...MODEL_TIERS.mainstream };
    }
    return { ...MODEL_TIERS.entry };
  }

  function firstTokenLatency(tier) {
    if (tier === "flagship") return 350;
    if (tier === "mainstream") return 500;
    return 700;
  }

  function planPipeline(input) {
    const mode = input && input.mode;
    const tier = input && input.tier;
    const allowedModes = ["chat", "voice", "video"];

    if (!allowedModes.includes(mode)) {
      throw new Error("mode must be chat, voice, or video");
    }
    if (!MODEL_TIERS[tier]) {
      throw new Error("unknown model tier");
    }

    const llmFirstToken = firstTokenLatency(tier);
    let stages;

    if (mode === "chat") {
      stages = [
        { name: "本地上下文检索", targetMs: 70 },
        { name: "LLM 首 token", targetMs: llmFirstToken },
        { name: "UI 流式渲染", targetMs: 40 },
      ];
    } else if (mode === "voice") {
      stages = [
        { name: "VAD 判定说完", targetMs: 80 },
        { name: "ASR 尾句定稿", targetMs: tier === "entry" ? 220 : 200 },
        { name: "LLM 首 token", targetMs: llmFirstToken },
        { name: "TTS 首音频块", targetMs: tier === "entry" ? 140 : 120 },
        { name: "播放启动", targetMs: 20 },
      ];
    } else {
      stages = [
        { name: "关键帧抽取", targetMs: 80 },
        {
          name: "VLM 画面摘要",
          targetMs: tier === "flagship" ? 250 : tier === "mainstream" ? 400 : 700,
        },
        { name: "视觉上下文压缩", targetMs: 40 },
        { name: "LLM 首 token", targetMs: llmFirstToken },
        { name: "TTS 首音频块", targetMs: tier === "entry" ? 140 : 120 },
      ];
    }

    const totalMs = stages.reduce((sum, stage) => sum + stage.targetMs, 0);
    return {
      mode,
      tier,
      stages: stages.map((stage) => ({ ...stage })),
      totalMs,
      meetsTarget: totalMs <= 1200,
    };
  }

  const CONVERSATION_TRANSITIONS = Object.freeze({
    idle: {
      start_call: "listening",
      submit_text: "thinking",
    },
    listening: {
      user_stop: "thinking",
      interrupt: "listening",
      stop_call: "idle",
    },
    thinking: {
      first_token: "speaking",
      text_response: "idle",
      interrupt: "listening",
      stop_call: "idle",
      error: "idle",
    },
    speaking: {
      tts_done: "listening",
      interrupt: "listening",
      stop_call: "idle",
      error: "idle",
    },
  });

  function conversationTransition(state, event) {
    const nextState = CONVERSATION_TRANSITIONS[state] && CONVERSATION_TRANSITIONS[state][event];
    return nextState || null;
  }

  function interruptAction(state) {
    if (state === "speaking") {
      return {
        stopTts: true,
        dropQueuedAudio: true,
        cancelInference: true,
        nextState: "listening",
      };
    }
    if (state === "thinking") {
      return {
        stopTts: false,
        dropQueuedAudio: false,
        cancelInference: true,
        nextState: "listening",
      };
    }
    if (state === "listening") {
      return {
        stopTts: false,
        dropQueuedAudio: false,
        cancelInference: false,
        nextState: "listening",
      };
    }
    return null;
  }

  function chooseReply(input) {
    const mode = input && input.mode;
    const message = String((input && input.message) || "").trim();
    const lowerMessage = message.toLowerCase();

    if (!message) {
      return "请输入内容。";
    }
    if (mode === "voice") {
      if (message.includes("提醒") || message.includes("日程")) {
        return "可以。你要设几点提醒？";
      }
      if (message.includes("看") || lowerMessage.includes("look")) {
        return "我先抽取关键帧，再给你短结论。";
      }
      return "好的，我在听。";
    }
    if (mode === "video") {
      if (message.includes("什么") || message.includes("看")) {
        return "根据本地画面摘要，这是一张模拟桌面场景，包含文档、咖啡杯和手机。";
      }
      return "我已经基于本地视觉摘要理解画面，你可以继续问细节。";
    }
    if (message.includes("提醒") || message.includes("日程")) {
      return "我可以调用本地日程工具创建提醒；当前原型只展示交互，不访问系统权限。";
    }
    return "这是端侧助手的确定性模拟回复；真实模型将在 M1 阶段接入 InferenceEngine。";
  }

  function privacyAudit(events) {
    const list = Array.isArray(events) ? events : [];
    const networkEvents = list.filter((event) => event && event.type === "network_request");
    return {
      totalEvents: list.length,
      networkRequests: networkEvents.length,
      localOnly: networkEvents.length === 0,
      summary:
        networkEvents.length === 0
          ? "当前会话无网络请求，符合端侧优先约束。"
          : `检测到 ${networkEvents.length} 次网络请求，需要用户显式授权。`,
    };
  }

  return {
    MODEL_TIERS,
    classifyDevice,
    planPipeline,
    conversationTransition,
    interruptAction,
    chooseReply,
    privacyAudit,
  };
});

