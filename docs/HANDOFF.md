# Handoff

## 当前交付

- `docs/design.md`：完整产品设计、架构、数据模型、边界和验收清单。
- `docs/adr/0001-on-device-first-architecture.md`：端侧优先架构决策。
- `docs/adr/0002-model-tiering-and-asset-delivery.md`：模型分级与资产分发决策。
- `docs/adr/0003-thermal-power-degradation.md`：温控与功耗分级降级决策。
- `docs/adr/0004-ios-engineering-stack.md`：iOS 工程结构与后端协议决策。
- `docs/adr/0005-in-app-model-store.md`：应用内模型商店决策。
- `docs/adr/0006-mlx-ios-inference-backend.md`：MLX Swift LM 真实文字推理决策。
- `docs/adr/0007-agent-memory-and-local-persistence.md`：Agent 记忆与本地持久化方向。
- `docs/adr/0008-model-discovery-and-multi-backend-compatibility.md`：联网模型发现、架构白名单与 MLX/VLM 后端。
- `docs/adr/0009-explicit-web-retrieval-tool.md`：显式检索与本地记忆边界。
- `docs/adr/0010-model-install-preflight-and-multimodal-status.md`：模型安装预检与多模态边界。
- `docs/adr/0011-runtime-aware-model-discovery.md`：运行时感知模型发现。
- `docs/roadmap.md`：阶段进展和后续计划。
- `prototype/`：浏览器架构原型。
- `prototype/js/inference-engine.js`：推理生命周期、能力门控、流式输出和取消参考实现。
- `prototype/js/model-registry.js`：模型资产注册、SHA-256 校验、失败保护与单步回滚。
- `prototype/js/asset-installer.js`：自带资产目录与自动装载编排器（校验 → 激活 → 进度上报，启动即执行）。
- `test/`：核心纯函数测试。
- `docs/api/inference-engine.md`：跨平台推理接口契约。
- `docs/design-ios.md`：iOS 实现级详细设计（工程结构、协议语义、安全与温控映射）。
- `docs/progress.md`：**唯一权威进度记录**，含任务清单（IOS-1～IOS-24）、验证命令与恢复检查单。
- `ios/`：`EdgeAssistantCore` Swift Package——域层已完成，56 项 `swift test` 全绿（ADR 0004/0010/0012/0013/0014），含热状态迟滞控制器、模型商店、远程模型发现、加密 Agent Store、分层记忆生命周期、混合召回、Mock、MLX 与 MLX-VLM 推理。
- `EdgeAssistant.xcodeproj` + `ios/EdgeAssistantApp/`：SwiftUI App 壳与聊天 UI（IOS-11/12/16），已在 iOS 模拟器端到端验证：启动自动装载 → 聊天流式调用内置模型 → 指标展示 → 打断；热通知触发热档位徽标与降级门控。
- `ios/Sources/EdgeAssistantCore/MLXInferenceEngine.swift` + `ios/Sources/EdgeAssistantCore/MLXVisionLanguageEngine.swift` + `ios/Sources/EdgeAssistantCore/InferenceEngineFactory.swift`：IOS-13 真实文字/VLM 推理接入（MLX Swift LM `3.32.3`）。iOS Simulator 构建通过；真实模型输出待真机下载验收。
- `ios/Sources/EdgeAssistantCore/RemoteModelCatalog.swift` + `ios/Sources/EdgeAssistantCore/ModelStore.swift` + `ios/EdgeAssistantApp/ModelStoreView.swift`：联网模型发现、MLX 布局与兼容性白名单、量化变体多路搜索、config/manifest/权重镜像回退、动态 manifest、分片下载与空间门控（ADR 0008/0011）；结果按可运行/轻量排序并显示内存负担；下载显示解析/进度/激活状态并自动激活；MLX 产物激活真实引擎，内置模拟资产支持显式切回 Mock。
- `ios/Sources/EdgeAssistantCore/RemoteFileValidator.swift` + `ios/Sources/EdgeAssistantCore/ModelStore.swift`：下载 JSON/Safetensors/Jinja 结构校验、镜像回退与激活目录预检；App 激活会调用 `InferenceEngine.prepare()` 预热真实 MLX/VLM 容器（ADR 0010）。
- `ios/Sources/EdgeAssistantCore/AgentMemory.swift` + `ios/Sources/EdgeAssistantCore/AgentTools.swift`：AES-GCM 密文 SQLite、旧 JSON 迁移、Agent 数据密钥生命周期与显式 Tavily 检索（ADR 0009/0013）。
- `ios/EdgeAssistantApp/Assets.xcassets/AppIcon.appiconset`：专用 App 图标（IOS-19），已在模拟器主屏确认。

## 关键决策

1. 默认端侧推理，不上传音频、图像、屏幕内容或记忆。
2. 不做静默云端兜底；未来云端能力必须是显式开关。
3. 按设备 RAM 和 NPU 能力划分 Flagship、Mainstream、Entry 三档。
4. 视频理解采用关键帧 + 语义压缩，不逐帧理解。
5. 语音通话优先保证短回复、低延迟和可打断。
6. 模型资产安装必须先校验；校验失败不能替换当前可用资产，成功安装保留单步回滚。
7. 温控采用四级分级主动降级（normal/warm/hot/critical），恢复逐级迟滞，见 ADR 0003。
8. 上下文按模式显式预算（chat 4K / voice 2K / video 4K，目标值待实测校准），超限淘汰最旧中间轮次。
9. 工具调用全部本地执行，按工具粒度授权（`tool_grants`），未授权直接拒绝。
10. 打断语义：任何阶段打断都停播、丢帧并取消未完成推理；状态机不设中间清理态。
11. 安装即内置：模型经 install-time asset pack 在系统安装 App 时落盘；首次启动自动校验 SHA-256 → 激活 → 装载，无用户操作、无网络；校验失败不改变已激活资产。
12. iOS 域层用 Swift Package 承载，推理后端收敛到 `InferenceEngine` 协议（ADR 0004）；M1 用 Mock 后端固化语义，真实后端按协议接入。
13. 新会话恢复工作先读 `docs/progress.md`。
14. App 启动即自动装载（`AppModel.autoProvision`），聊天直接调用内置模型；打断即取消推理；`--auto-chat` 为 DEBUG-only 端到端验证参数。
15. 热档位升级立即生效，恢复每级停留 ≥ 60s 且每次只恢复一级；`critical` 阻止新推理并取消已有生成，同时保留输入。
16. 商店下载必须显式触发；激活共用 `InferenceEngine` 契约；激活中的模型禁止删除。
17. 激活必须通过结构预检和 `prepare()` 真实容器预热；失败保留旧引擎并显示具体文件。
19. MLX Swift LM 锁定 `3.32.x`（当前 `3.32.3`），平台最低 iOS 17 / macOS 14；文本 `mlx` 资产走 `MLXInferenceEngine`，`mlx-vlm` 资产走 `MLXVisionLanguageEngine`。VLM 当前只启用纯文字对话。
20. 模型下载主源超时后回退镜像；大文件请求/资源超时均为 7 天。切换模型前先打断当前生成。
21. Agent 会话/事实已进入 AES-GCM 加密 SQLite，密钥在 Keychain；清除数据先销毁密钥。记忆已分层 semantic/episodic，pending 候选不注入 prompt；混合召回和工作记忆预算见 ADR 0014。
22. 模型发现不因仓库名承诺可执行；`minicpmv4_7` 当前 unsupported，原生 MNN requiresConversion，只有白名单架构可下载。
23. 联网检索默认关闭；开启后检索 query 出设备、模型推理不出设备，来源必须展示，失败降级本地。
24. 运行时发现必须先命中 MLX 权重布局，再命中对齐 registry 的架构；普通搜索词扩展 MLX-community 4bit/8bit 变体，最多探测 12 个候选且单候选失败不阻断搜索。
25. 主源 manifest 不可达且存在 `mirrorBase` 时，解析和文件 URL 直接切换镜像；这只是源站回退，不是 HTTP Range 断点续传。
26. 下载失败/解析失败/进度/取消都绑定在候选模型行内；页面顶部只保留搜索与激活类全局提示。
27. MLX 下载可在 iOS 模拟器完成并入库；模拟器激活前提示真机执行，防止 MLX Metal Device 初始化 abort。
28. 激活前必须通过 `ModelMemoryGate`；`os_proc_available_memory()` 加权重必须小于可用内存，并预留 1.5GB 上下文/Metal buffer，否则提示换小模型。
29. 商店结果先按 `supported` 排序，再按权重体积升序；轻量/中量/重量标签只是选择辅助，不能替代激活前的内存护栏。
30. `config.json` 探测、manifest 和权重下载必须支持 `hf-mirror.com` 回退；远程候选也配置镜像，不能“搜索得到但下载不了”。
31. MLX 静态 supported 模型必须解析完整远端 manifest，确保 chat template/generation 配置不缺；身份提示只在 system 消息出现一次。
32. 商店下载写入 `.staging/<id>`，完整校验后原子提升；无 metadata/坏 metadata 残留与中断 staging 可枚举和清理，带 metadata 不完整安装走修复下载。聊天解析明确字数意图，normal 档最高 2000 字；MLX 生成在 60 秒无首 token 或 45 秒无增量时报错。

## 下一步建议

1. **IOS-13/20/23c 真机验收**：联网搜索 `qwen`、`gemma`、`smollm`，优先安装轻量 supported 模型，验证解析/下载/自动激活状态、MLX/VLM 加载、流式渲染、打断、指标和温控降级；确认 MiniCPM/MNN 不可直接部署。
2. **Agent 真机验收**：重启验证记忆/会话恢复；开启 Tavily 验证来源、引用与失败降级。
3. **IOS-18 后续**：在真实语料评审设备端 embedding、加密索引、主题分区和来源审计。
4. **IOS-14**：在 iOS 真机建立三档基准；Android 后端和旗舰/主流机型基准可在 iOS 语义稳定后并行选型。
5. 后端稳定后再推进 M2 实时语音链路。

## 验证方式

```bash
cd edge-assistant
npm test
```

iOS 域层：

```bash
cd edge-assistant/ios
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/eac-clang-cache \
  swift test --disable-sandbox \
  --cache-path /private/tmp/eac-cache --manifest-cache local --scratch-path .build
```

iOS App 构建：

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project EdgeAssistant.xcodeproj -scheme EdgeAssistant \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/edge-assistant-dd \
  -clonedSourcePackagesDirPath /private/tmp/edge-assistant-pkgs \
  -skipMacroValidation build
```

首次构建 MLX 依赖若提示缺少 Metal Toolchain：

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -downloadComponent MetalToolchain
```

浏览器原型：

```bash
cd edge-assistant/prototype
python3 -m http.server 4173
```

然后访问 `http://localhost:4173/`。

