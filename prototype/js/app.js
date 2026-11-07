(function () {
  "use strict";

  const {
    classifyDevice,
    planPipeline,
    conversationTransition,
    interruptAction,
    chooseReply,
  } = window.EdgeAssistant;
  const {
    createSimulatedModelBundle,
    createModelAssetManager,
  } = window.EdgeAssistantModelRegistry;
  const { createInferenceEngine } = window.EdgeAssistantInferenceEngine;
  const {
    createBundledAssetCatalog,
    createAutoInstaller,
  } = window.EdgeAssistantAssetInstaller;

  const state = {
    ramGb: 12,
    hasNpu: true,
    tier: "flagship",
    mode: "chat",
    callState: "idle",
    timers: [],
    manager: createModelAssetManager(),
    engine: null,
    voiceAbortController: null,
    runtimeRequestId: 0,
    installedTier: null,
    catalog: null,
    installer: null,
  };

  state.engine = createInferenceEngine({
    buildReply: chooseReply,
    latencyProfile: (mode) => {
      if (mode === "video") {
        return state.tier === "flagship" ? 250 : state.tier === "mainstream" ? 400 : 700;
      }
      return state.tier === "flagship" ? 350 : state.tier === "mainstream" ? 500 : 700;
    },
  });

  const elements = {
    ramSelect: document.getElementById("ram-select"),
    npuCheckbox: document.getElementById("npu-checkbox"),
    tierLabel: document.getElementById("tier-label"),
    assetSize: document.getElementById("asset-size"),
    modelName: document.getElementById("model-name"),
    tierDescription: document.getElementById("tier-description"),
    runtimeState: document.querySelector("#runtime-status .status-chip"),
    runtimeModel: document.getElementById("runtime-model"),
    runtimeVersion: document.getElementById("runtime-version"),
    runtimeHash: document.getElementById("runtime-hash"),
    runtimeLog: document.getElementById("runtime-log"),
    installModel: document.getElementById("install-model"),
    corruptModel: document.getElementById("corrupt-model"),
    rollbackModel: document.getElementById("rollback-model"),
    onboarding: document.getElementById("install-onboarding"),
    onboardingCopy: document.getElementById("onboarding-copy"),
    onboardingLog: document.getElementById("onboarding-log"),
    retryInstall: document.getElementById("retry-install"),
    modeTabs: Array.from(document.querySelectorAll(".mode-tab")),
    pipelineContainer: document.getElementById("pipeline-container"),
    budgetResult: document.getElementById("budget-result"),
    chatForm: document.getElementById("chat-form"),
    chatInput: document.getElementById("chat-input"),
    messages: document.getElementById("messages"),
    voiceState: document.getElementById("voice-state"),
    voiceOrb: document.getElementById("voice-orb"),
    voiceCaption: document.getElementById("voice-caption"),
    voiceMessages: document.getElementById("voice-messages"),
    voiceInput: document.getElementById("voice-input"),
    startCall: document.getElementById("start-call"),
    simulateUser: document.getElementById("simulate-user"),
    interruptCall: document.getElementById("interrupt-call"),
    endCall: document.getElementById("end-call"),
    captureFrame: document.getElementById("capture-frame"),
    visionSummary: document.getElementById("vision-summary"),
    videoForm: document.getElementById("video-form"),
    videoInput: document.getElementById("video-input"),
    videoMessages: document.getElementById("video-messages"),
  };

  function clearTimers() {
    state.timers.forEach((timer) => window.clearTimeout(timer));
    state.timers = [];
  }

  function schedule(callback, delay) {
    const timer = window.setTimeout(() => {
      state.timers = state.timers.filter((item) => item !== timer);
      callback();
    }, delay);
    state.timers.push(timer);
  }

  function appendMessage(container, role, text) {
    const message = document.createElement("div");
    message.className = `message ${role}`;
    message.textContent = text;
    container.appendChild(message);
    container.scrollTop = container.scrollHeight;
  }

  function renderRuntime(logMessage) {
    const engineStatus = state.engine.status();
    const managerStatus = state.manager.status();
    const asset = engineStatus.asset || managerStatus.activeAsset;

    elements.runtimeState.textContent = engineStatus.state;
    elements.runtimeState.className = `status-chip ${
      engineStatus.state === "ready" ? "" : engineStatus.state === "unloaded" ? "warn" : "error"
    }`;
    elements.runtimeModel.textContent = asset ? asset.id : "尚未装载模型";
    elements.runtimeVersion.textContent = asset ? asset.version : "—";
    elements.runtimeHash.textContent = asset ? `${asset.sha256.slice(0, 16)}…` : "—";
    elements.runtimeLog.textContent =
      logMessage ||
      managerStatus.lastError ||
      (asset ? "模型已通过 SHA-256 校验，本地推理引擎就绪。" : "等待模型装载。");
    elements.rollbackModel.disabled =
      !managerStatus.rollbackAsset || managerStatus.rollbackAsset.tier !== state.tier;
  }

  function renderAutoCard() {
    const bundle = state.catalog ? state.catalog.get(state.tier) : null;
    elements.onboarding.hidden = false;
    if (bundle) {
      const sizeGb = (bundle.asset.sizeBytes / 1_000_000_000).toFixed(1);
      elements.onboardingCopy.textContent = `模型随 App 一并安装到手机（${bundle.asset.tier} · ${sizeGb}GB），首次启动自动校验装载，聊天直接调用内置模型。`;
    } else {
      elements.onboardingCopy.textContent = "正在读取自带模型资产目录…";
    }
  }

  async function autoProvisionModel() {
    if (!state.installer) {
      return;
    }
    elements.retryInstall.hidden = true;
    state.runtimeRequestId += 1;
    const requestId = state.runtimeRequestId;

    try {
      const result = await state.installer.installForTier(state.tier);
      if (requestId !== state.runtimeRequestId) {
        return;
      }

      if (result.ok) {
        const loadedAsset = state.engine.status().asset;
        if (loadedAsset && loadedAsset.tier !== state.tier) {
          state.engine.unload();
        }
        state.engine.load(result.asset);
        state.installedTier = state.tier;
        renderAutoCard();
        elements.onboardingLog.textContent = "内置模型已就绪，聊天直接调用，无需任何操作。";
        renderRuntime(
          `内置模型 ${result.asset.id} 已自动通过 SHA-256 校验并装载；可回滚资产：${
            result.status.rollbackAssetId || "无"
          }。`
        );
      } else {
        const reasonText =
          result.reason === "insufficient-storage"
            ? `存储空间不足（需要 ${(result.requiredBytes / 1_000_000_000).toFixed(
                1
              )}GB，可用 ${(result.availableBytes / 1_000_000_000).toFixed(1)}GB）`
            : `校验失败：${result.reason}`;
        elements.onboardingLog.textContent = `自动装载失败：${reasonText}。已激活资产未改变。`;
        elements.retryInstall.hidden = false;
        renderRuntime();
      }
    } catch (error) {
      if (requestId === state.runtimeRequestId) {
        elements.onboardingLog.textContent = `自动装载异常：${error.message}`;
        elements.retryInstall.hidden = false;
      }
    }
  }

  async function initBundledCatalog() {
    state.catalog = await createBundledAssetCatalog();
    state.installer = createAutoInstaller({
      catalog: state.catalog,
      manager: state.manager,
      onProgress: (event) => {
        const stageText =
          {
            "storage-check": "检查存储空间",
            verify: "校验 SHA-256",
            activate: "激活资产",
          }[event.stage] || event.stage;
        elements.onboardingLog.textContent =
          event.ok === false
            ? `${stageText}失败${event.reason ? `：${event.reason}` : ""}。`
            : `${stageText}…`;
      },
    });
    // 安装即内置：资产目录就绪后自动校验装载，不需要用户点击。
    renderAutoCard();
    await autoProvisionModel();
  }

  async function installSimulatedModel(options = {}) {
    const requestId = state.runtimeRequestId + 1;
    state.runtimeRequestId = requestId;
    elements.installModel.disabled = true;
    elements.corruptModel.disabled = true;
    elements.runtimeLog.textContent = options.corrupt
      ? "正在验证损坏资产，失败时应保留当前可用模型..."
      : "正在校验模型资产 SHA-256...";

    try {
      const loadedAsset = state.engine.status().asset;
      if (loadedAsset && loadedAsset.tier !== state.tier) {
        state.engine.unload();
      }
      const bundle = await createSimulatedModelBundle(
        state.tier,
        "1.0.0",
        options.corrupt ? { corrupt: true } : {}
      );
      if (requestId !== state.runtimeRequestId) {
        return;
      }

      const result = await state.manager.install(bundle.asset, bundle.bytes);
      if (requestId !== state.runtimeRequestId) {
        return;
      }

      if (result.ok) {
        state.engine.load(bundle.asset);
        state.installedTier = bundle.asset.tier;
        renderAutoCard();
        elements.onboardingLog.textContent = "内置模型已就绪，聊天直接调用，无需任何操作。";
        renderRuntime(
          `模型 ${bundle.asset.id} 校验通过并已装载；可回滚资产：${
            result.status.rollbackAssetId || "无"
          }。`
        );
      } else {
        renderRuntime(
          `资产校验失败：${result.reason}。当前模型保持不变，避免损坏资产进入运行时。`
        );
      }
    } catch (error) {
      if (requestId === state.runtimeRequestId) {
        renderRuntime(`模型装载异常：${error.message}`);
      }
    } finally {
      if (requestId === state.runtimeRequestId) {
        elements.installModel.disabled = false;
        elements.corruptModel.disabled = false;
      }
    }
  }

  function renderModelTier() {
    const profile = classifyDevice({
      ramGb: state.ramGb,
      hasNpu: state.hasNpu,
    });

    state.tier = profile.tier;
    elements.tierLabel.textContent = profile.label;
    elements.assetSize.textContent = profile.assetSizeGb;
    elements.modelName.textContent = profile.model;
    elements.tierDescription.textContent = profile.description;

    elements.modeTabs.forEach((tab) => {
      const mode = tab.dataset.mode;
      tab.disabled = !profile.modes.includes(mode);
    });

    if (!profile.modes.includes(state.mode)) {
      setMode("chat");
    } else {
      renderPipeline();
    }

    if (state.installedTier && state.installedTier !== profile.tier) {
      installSimulatedModel();
    } else if (!state.installedTier) {
      renderAutoCard();
      elements.onboardingLog.textContent = "正在准备自带模型，启动后自动校验装载…";
    }
  }

  function renderPipeline() {
    const plan = planPipeline({ mode: state.mode, tier: state.tier });
    elements.pipelineContainer.innerHTML = "";

    plan.stages.forEach((stage) => {
      const row = document.createElement("div");
      row.className = "pipeline-stage";

      const name = document.createElement("strong");
      name.textContent = stage.name;
      const latency = document.createElement("span");
      latency.textContent = `${stage.targetMs}ms`;

      row.append(name, latency);
      elements.pipelineContainer.appendChild(row);
    });

    elements.budgetResult.textContent = `预算总计：${plan.totalMs}ms · ${
      plan.meetsTarget ? "满足 <1.2s 目标" : "超过 1.2s，需要降级策略"
    }`;
    elements.budgetResult.style.color = plan.meetsTarget ? "#047857" : "#b45309";
  }

  function setMode(mode) {
    const activeTab = elements.modeTabs.find((tab) => tab.dataset.mode === mode);
    if (!activeTab || activeTab.disabled) {
      return;
    }

    state.mode = mode;
    elements.modeTabs.forEach((tab) => tab.classList.toggle("active", tab.dataset.mode === mode));
    document.querySelectorAll(".mode-view").forEach((view) => {
      view.classList.toggle("active", view.id === `${mode}-mode`);
    });
    renderPipeline();
  }

  function setCallState(nextState, caption) {
    state.callState = nextState;
    elements.voiceState.textContent = nextState;
    elements.voiceOrb.dataset.state = nextState;
    elements.voiceCaption.textContent = caption;
    updateVoiceButtons();
  }

  function transitionCall(event, caption) {
    const next = conversationTransition(state.callState, event);
    if (!next) {
      return false;
    }
    setCallState(next, caption);
    return true;
  }

  function updateVoiceButtons() {
    const active = state.callState !== "idle";
    elements.startCall.disabled = active;
    elements.simulateUser.disabled = state.callState !== "listening";
    elements.interruptCall.disabled = state.callState === "idle";
    elements.endCall.disabled = !active;
  }

  async function streamAssistantReply(container, mode, prompt, options = {}) {
    const message = appendMessage(container, "assistant", "");
    let sawFirstToken = false;

    try {
      for await (const event of state.engine.generateStream({
        mode,
        prompt,
        signal: options.signal,
      })) {
        if (event.type === "token") {
          if (!sawFirstToken) {
            sawFirstToken = true;
            if (options.onFirstToken) {
              options.onFirstToken();
            }
          }
          message.textContent += event.text;
          container.scrollTop = container.scrollHeight;
        }
      }
    } catch (error) {
      if (error.name === "AbortError") {
        appendMessage(container, "system", "推理已取消，未完成内容不会继续输出。");
      } else {
        appendMessage(container, "system", `本地推理失败：${error.message}`);
      }
    }
  }

  async function sendChat(event) {
    event.preventDefault();
    const text = elements.chatInput.value.trim();
    if (!text) {
      return;
    }
    if (state.engine.status().state !== "ready") {
      appendMessage(
        elements.messages,
        "system",
        "内置模型正在自动装载，请稍候。"
      );
      return;
    }

    appendMessage(elements.messages, "user", text);
    elements.chatInput.value = "";
    await streamAssistantReply(elements.messages, "chat", text);
  }

  function simulateVoiceTurn() {
    if (state.callState !== "listening") {
      return;
    }
    if (state.engine.status().state !== "ready") {
      appendMessage(
        elements.voiceMessages,
        "system",
        "内置模型正在自动装载，无法开始推理，请稍候。"
      );
      return;
    }

    const transcript = elements.voiceInput.value.trim() || "帮我设一个提醒";
    appendMessage(elements.voiceMessages, "user", transcript);
    transitionCall("user_stop", "ASR 定稿，LLM 生成首 token...");

    const controller = new AbortController();
    state.voiceAbortController = controller;

    schedule(async () => {
      if (state.callState !== "thinking") {
        return;
      }
      await streamAssistantReply(elements.voiceMessages, "voice", transcript, {
        signal: controller.signal,
        onFirstToken: () => {
          transitionCall("first_token", "TTS 流式播放中，可随时打断。");
        },
      });

      if (state.callState === "speaking" && !controller.signal.aborted) {
        schedule(() => {
          if (state.callState === "speaking") {
            transitionCall("tts_done", "播放完成，回到监听状态。");
          }
        }, 600);
      }
    }, 500);
  }

  function interruptVoice() {
    const action = interruptAction(state.callState);
    if (!action) {
      return;
    }

    clearTimers();
    if (state.voiceAbortController) {
      state.voiceAbortController.abort();
      state.voiceAbortController = null;
    }
    setCallState(
      action.nextState,
      action.stopTts
        ? "已停止 TTS、丢弃音频队列，回到监听。"
        : "已取消未完成推理，回到监听。"
    );
    appendMessage(elements.voiceMessages, "system", "用户打断：立即停播并丢帧。");
  }

  function endCall() {
    clearTimers();
    if (state.voiceAbortController) {
      state.voiceAbortController.abort();
      state.voiceAbortController = null;
    }
    transitionCall("stop_call", "通话结束，音频资源已释放。");
  }

  function captureVisionFrame() {
    elements.captureFrame.disabled = true;
    elements.visionSummary.textContent = "正在抽取关键帧并运行本地 VLM 摘要...";

    schedule(() => {
      elements.visionSummary.textContent =
        "本地视觉摘要：桌面场景，包含一份打开的文档、一杯咖啡和一部手机。OCR 检测到标题“Edge Assistant Design”。未上传画面，未持久化关键帧。";
      elements.captureFrame.disabled = false;
    }, 600);
  }

  async function sendVisionQuestion(event) {
    event.preventDefault();
    const text = elements.videoInput.value.trim();
    if (!text) {
      return;
    }
    if (state.engine.status().state !== "ready") {
      appendMessage(
        elements.videoMessages,
        "system",
        "内置模型正在自动装载，无法回答视觉问题，请稍候。"
      );
      return;
    }

    appendMessage(elements.videoMessages, "user", text);
    await streamAssistantReply(elements.videoMessages, "video", text);
  }

  elements.ramSelect.addEventListener("change", (event) => {
    state.ramGb = Number(event.target.value);
    renderModelTier();
  });

  elements.npuCheckbox.addEventListener("change", (event) => {
    state.hasNpu = event.target.checked;
    renderModelTier();
  });

  elements.modeTabs.forEach((tab) => {
    tab.addEventListener("click", () => setMode(tab.dataset.mode));
  });

  elements.chatForm.addEventListener("submit", sendChat);
  elements.startCall.addEventListener("click", () => {
    transitionCall("start_call", "正在监听。点击“模拟用户说完”进入下一状态。");
  });
  elements.simulateUser.addEventListener("click", simulateVoiceTurn);
  elements.interruptCall.addEventListener("click", interruptVoice);
  elements.endCall.addEventListener("click", endCall);
  elements.captureFrame.addEventListener("click", captureVisionFrame);
  elements.videoForm.addEventListener("submit", sendVisionQuestion);
  elements.installModel.addEventListener("click", () => installSimulatedModel());
  elements.retryInstall.addEventListener("click", () => autoProvisionModel());
  elements.corruptModel.addEventListener("click", () =>
    installSimulatedModel({ corrupt: true })
  );
  elements.rollbackModel.addEventListener("click", async () => {
    const result = await state.manager.rollback();
    if (result.ok && result.status.activeAsset) {
      state.engine.load(result.status.activeAsset);
      renderRuntime(`已回滚到模型 ${result.status.activeAsset.id}。`);
    } else {
      renderRuntime("没有可回滚的模型资产。");
    }
  });

  appendMessage(
    elements.messages,
    "assistant",
    "你好，我是端侧助手原型。当前演示的是架构和状态机，不包含真实模型推理。"
  );
  renderModelTier();
  initBundledCatalog();
  updateVoiceButtons();
  renderRuntime();
})();

