# Edge Assistant

Edge Assistant 是一个端侧优先的移动 AI 助手设计项目，目标是在手机本地运行量化大模型，并支持文字聊天、App 内语音通话和摄像头/屏幕理解。

## 当前状态

**M1：推理抽象与模型资产进行中**

本地源码托管在 Git `main` 分支；构建产物、SwiftPM 缓存、Xcode 用户数据和 `.DS_Store` 已加入 `.gitignore`。

当前包含：

- 完整产品设计文档。
- 端侧优先架构 ADR。
- 模型分级与资产分发 ADR。
- 浏览器交互原型，用于验证机型分级、状态机和延迟预算。
- `InferenceEngine` 平台无关参考实现。
- 模型资产注册、SHA-256 校验、失败安装保护与单步回滚。
- 安装即内置：模型随 App 自带，启动自动校验装载，聊天直接调用内置模型（无网络、无用户操作）。
- iOS 热状态监听与四级降级：升级立即生效，恢复逐级迟滞；`critical` 暂停发送但保留输入。
- 应用内模型商店管理链路：显式下载、校验、激活、切换和删除。
- 可靠安装与残留修复（IOS-24）：下载写入 `.staging`，完整校验后原子入库；取消/失败可复用完整文件，无 metadata/坏 metadata 残留与中断缓存可枚举和清理，不完整安装可修复下载。
- iOS MLX/MLX-VLM 真实推理后端（MLX Swift LM `3.32.3`）：文本资产走 `MLXInferenceEngine`，`mlx-vlm` 资产走 `MLXVisionLanguageEngine`；内置模拟资产继续走 Mock。真实模型输出待真机下载验收。
- 联网模型发现与兼容性校验：查询 HuggingFace 候选，自动扩展 `mlx-community` 4bit/8bit 变体；先确认 MLX 权重布局，再读取 `config.json` 架构与文件树；只有 MLX runtime 白名单架构允许下载。搜索并行、最多探测 12 个候选，结果优先展示可运行且轻量的模型；`config.json`、manifest 和权重在主源不可用时回退 `hf-mirror`。分片下载、流式 SHA-256、JSON/Safetensors 结构校验、完整 chat template 清单、行内解析/进度/激活错误/取消、内存负担标签、自动激活状态与激活预检已接入。
- 分层本地 Agent 记忆（IOS-15/18）：会话与身份/偏好事实写入 AES-GCM 加密 SQLite；记忆区分语义/情景和已确认/待确认，待确认不注入回答；本地混合召回按词汇、时间、类型排序，并遵守 5 条 / 1200 字预算。数据密钥在 Keychain，清除数据会销毁密钥并删除密文。
- 显式联网检索：默认关闭；开启后通过 Tavily 检索，API Key 存 Keychain 且可在设置中删除，来源带 URL 展示，检索失败降级本地。
- 专用 App 图标（IOS-19）与多模型商店切换链路。
- 核心纯函数与推理生命周期测试。

当前不包含：

- 已下载的真实大模型权重。
- 已在真机完成的 MLX 输出、延迟和打断验收基准。
- 设备端语义 embedding、加密向量索引、主题分区和记忆来源审计（IOS-18 后续）。
- Gemma 4 真实权重加载/输出验收、图像输入。
- 文件附件、图片输入、ASR/TTS、语音通话（语音状态机已设计，完整管线未实现）。
- MiniCPM-V 4.7 35B-A3B 运行时与原生 MNN Pocket 直接执行。
- 真实电话网络接入。
- 真实摄像头采集。
- 应用商店发布包。

## 运行原型

无需安装依赖：

```bash
cd prototype
python3 -m http.server 4173
```

打开：

```text
http://localhost:4173/
```

也可以直接用浏览器打开 `prototype/index.html`。

## 运行测试

```bash
npm test
```

测试使用 Node 内置 `node:test`，无第三方依赖。

## iOS 开发（M1-iOS 进行中）

iOS App 已可在模拟器运行：`EdgeAssistant.xcodeproj`（仓库根目录）构建通过，启动自动校验装载内置模拟模型（无网络、无用户操作），聊天流式输出并展示推理指标，支持打断；系统热状态会显示 UI 徽标并按设计降级或暂停推理。商店优先显示轻量可运行模型，每项显示下载体积、内存负担和本机风险；下载阶段显示解析清单、进度、行内错误和激活状态，主源不可用时自动回退镜像；旧安装若缺新 manifest 必需文件会自动修复，无 metadata/坏 metadata 残留和中断缓存可在商店清理后重新下载。聊天会识别明确字数要求（normal 档最高 2000 字），展示准备/生成状态，并在 60 秒无首 token 或 45 秒无增量时给出超时错误。下载完成后先通过文件/内存预检，再激活 MLX Swift LM。权重必须由用户显式下载；iOS 模拟器可下载入库但 MLX 推理需真机，低内存真机会被内存护栏阻断并提示换小模型。域层 `EdgeAssistantCore` Swift Package 56 项 `swift test` 全绿。

在 Xcode 中打开 `EdgeAssistant.xcodeproj`，选择 iPhone 模拟器直接 Cmd+R 运行；或命令行构建：

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

```bash
cd ios
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/eac-clang-cache \
  swift test --disable-sandbox \
  --cache-path /private/tmp/eac-cache --manifest-cache local --scratch-path .build
```

内置模拟模型输出为确定性 Mock；商店 MLX/MLX-VLM 模型激活后使用真实本地推理。当前指定模型结论：**Gemma 4 E2B 已进入可下载/部署列表，真机待验**；**MiniCPM-V 4.7 35B-A3B 当前依赖不支持**；**原生 MNN Pocket 0.3B 需要转换，不能直接跑**。联网检索默认关闭，开启后只有检索请求出设备，模型推理仍本地。会话与长期记忆使用 AES-GCM 加密 SQLite；pending 候选不注入回答，清除数据会销毁数据密钥。真机模型验收进度见任务清单，实现设计见 [iOS 详细设计](docs/design-ios.md)。

## 文档入口

- [产品设计](docs/design.md)
- [iOS 详细设计](docs/design-ios.md)
- [进度与交接](docs/progress.md)
- [路线图](docs/roadmap.md)
- [交接文档](docs/HANDOFF.md)
- [ADR 0001：端侧优先架构](docs/adr/0001-on-device-first-architecture.md)
- [ADR 0002：模型分级与资产分发](docs/adr/0002-model-tiering-and-asset-delivery.md)
- [ADR 0003：温控与功耗分级降级](docs/adr/0003-thermal-power-degradation.md)
- [ADR 0004：iOS 工程结构与推理后端选型](docs/adr/0004-ios-engineering-stack.md)
- [ADR 0005：应用内模型商店](docs/adr/0005-in-app-model-store.md)
- [ADR 0006：MLX iOS 推理后端](docs/adr/0006-mlx-ios-inference-backend.md)
- [ADR 0007：Agent 记忆与本地持久化](docs/adr/0007-agent-memory-and-local-persistence.md)
- [ADR 0008：联网模型发现与兼容性白名单](docs/adr/0008-model-discovery-and-multi-backend-compatibility.md)
- [ADR 0009：显式联网检索](docs/adr/0009-explicit-web-retrieval-tool.md)
- [ADR 0010：模型安装与激活预检](docs/adr/0010-model-install-preflight-and-multimodal-status.md)
- [ADR 0011：运行时感知模型发现](docs/adr/0011-runtime-aware-model-discovery.md)
- [IOS-15 Agent Store 设计](docs/design/ios-15-agent-store.md)
- [ADR 0014：分层记忆与混合召回](docs/adr/0014-layered-agent-memory-and-hybrid-recall.md)
- [IOS-18 Agent 记忆设计](docs/design/ios-18-agent-memory.md)
- [Inference Engine API](docs/api/inference-engine.md)

## 核心原则

1. 默认本地推理，用户数据不出设备。
2. 云端能力必须显式授权，不做静默上传。
3. 按设备能力分级，不强行运行超出硬件能力的模型。
4. 语音体验优先保证低延迟和可打断。
5. 视频理解采用关键帧和语义压缩，不追求逐帧推理。

