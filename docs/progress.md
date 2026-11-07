# 开发进度与交接文档

> 本文档是唯一权威的进度记录。每次开发节点结束后必须更新。
> 新会话恢复工作的顺序：**先读本文件 → 再读 `docs/design-ios.md`（当前实现依据）→ 需要产品背景时读 `docs/design.md`**。

## 最后更新

2026-11-07 · IOS-18 第一阶段：semantic/episodic 分层记忆、confirmed/pending 生命周期、本地混合召回与工作记忆预算；语音仍为 M2 未实现

## 当前状态一句话

**iOS App 已可在模拟器上运行**：`EdgeAssistant.xcodeproj` 构建通过，启动自动装载内置 Mock 模型；商店 MLX 模型下载后自动激活并通过 `MLXInferenceEngine` 本地推理，Gemma 4 这类 `mlx-vlm` 资产走 `MLXVLM.VLMModelFactory`。模型下载现在写入 `.staging` 并在完整校验后原子入库；无 metadata/坏 metadata 残留与中断 staging 可在商店枚举和清理，带 metadata 的不完整安装可修复下载。模型商店仍可联网搜索 HuggingFace 候选；`config.json`、manifest 和权重在主源失败后自动回退 `hf-mirror`。必须同时命中 MLX 权重布局与 runtime registry 架构才允许下载。搜索会扩展 `mlx-community` 与 4bit/8bit 变体，文本/视觉请求并行，最多探测 12 个候选，单候选失败不拖垮搜索；候选优先按可运行和体积升序展示，并显示轻量/中量/重量内存负担。静态 supported 模型也解析完整远端 manifest，避免缺 chat template。聊天会识别“800 字”等明确长度意图（normal 档最高 2000 字），显示准备/生成状态；60 秒无首 token 或 45 秒无增量会显式超时。App 会话与长期事实持久化到 AES-GCM 加密 SQLite（ADR 0013），旧 JSON 自动迁移；Agent 数据密钥与 Tavily API Key 分别保存在 Keychain。设置页可保存、更新和删除 API Key，删除后关闭检索；“清除记忆与会话”先销毁数据密钥再清空密文。记忆已升级为 semantic/episodic 分层：显式“记住”直接 confirmed，推断候选 pending 且不注入 prompt；用户可单条确认、忽略、编辑、删除。召回使用本地字符/词特征、IDF、21 天时间衰减与类型权重，并按 5 条 / 1200 字预算装箱。联网检索仍只在用户显式开启后发起，来源带 URL 展示，失败降级本地。域层 56 项 `swift test` 全绿，JS 24 项全绿，iOS Simulator 构建通过。**真实多模型下载、输出与打断仍待真机验收。**

## 任务清单

状态图例：✅ 已完成 · 🔄 进行中 · ⬜ 未开始 · ⏸ 阻塞

| ID | 任务 | 状态 | 产出 / 备注 |
|---|---|---|---|
| IOS-0 | iOS 详细设计文档 | ✅ | `docs/design-ios.md` |
| IOS-0a | 技术选型 ADR | ✅ | `docs/adr/0004-ios-engineering-stack.md` |
| IOS-1 | Swift Package 工程骨架 | ✅ | `ios/Package.swift`；IOS-13 为支持 MLX 3.32.3 调整为 iOS 17+ / macOS 14+，Swift Tools 6.2 / 源码语言模式 v5 |
| IOS-2 | 档位与机型分级 | ✅ | `Tiers.swift`：`ModelTier` / `CapabilityMode` / `DeviceProfile` |
| IOS-3 | 延迟预算 + 语音状态机 + 打断动作 | ✅ | `Pipeline.swift`：`PipelinePlanner` / `ConversationStateMachine` / `Interrupt` |
| IOS-4 | 资产模型 + 元数据校验 + SHA-256 | ✅ | `ModelAsset.swift`（CryptoKit） |
| IOS-5 | 资产注册表（按档位选最新） | ✅ | `ModelRegistry.swift` |
| IOS-6 | 安装保护 + 单步回滚（actor） | ✅ | `ModelAssetManager.swift` |
| IOS-7 | 自带资产目录 + 自动装载编排器 | ✅ | `BundledAssets.swift`：`BundledAssetCatalog` / `AutoInstaller`（安装即内置语义） |
| IOS-8 | 推理协议 + Mock 后端（流式/取消/指标） | ✅ | `InferenceEngine.swift`：`InferenceEngine` 协议 / `MockInferenceEngine` |
| IOS-9 | 温控映射与降级动作 | ✅ | `Thermal.swift`：`ThermalMapper`（ProcessInfo 四级映射） |
| IOS-10 | 域层单元测试（对应 JS 原型测试） | ✅ | 原型对应测试全绿；当前域层累计 56 tests |
| IOS-11 | SwiftUI App 壳（Xcode 工程） | ✅ | `EdgeAssistant.xcodeproj`（根目录）+ `ios/EdgeAssistantApp/`；启动序列接 `AutoInstaller`，模拟器实机运行验证 |
| IOS-12 | 文字聊天 UI（调用内置模型） | ✅ | 流式渲染 + 指标系统消息 + 打断按钮；多行输入直达发送、暂停提示与模型商店直达入口；`--auto-chat` DEBUG 启动参数做端到端验证（截图确认） |
| IOS-12a | 应用内模型商店管理链路 | ✅ | `ModelStore.swift` + `ModelStoreView.swift`（ADR 0005）；下载/激活/删除已测试，MLX 产物激活真实引擎 |
| IOS-13 | 真实推理后端评估与接入 | 🔄 | 开发完成：MLX Swift LM `3.32.3`（ADR 0006）、`MLXInferenceEngine`、`MLXVisionLanguageEngine`、`InferenceEngineFactory`、App 引擎替换与镜像下载已接入；待真机下载权重验证真实输出 |
| IOS-14 | 三档设备基准测试 | ⬜ | 依赖 IOS-13 |
| IOS-15 | 加密数据库 + Keychain 密钥管理 | ✅ | `AgentMemoryStore` 使用 AES-GCM 密文 SQLite（ADR 0013）；旧 JSON 迁移删除；Agent master key 与 Tavily Key 独立保存、可管理；清除数据销毁数据密钥 |
| IOS-16 | 热状态监听接入 UI + 迟滞恢复 | ✅ | `ThermalHysteresisController` + App 热通知监听、状态徽标、`critical` 推理门控/取消、`warm/hot` 输出上限 |
| IOS-17 | 语音管线（AEC/VAD/ASR/TTS） | ⬜ | M2；不是文本模型能力不足，而是音频采集、ASR、TTS、播放和打断管线均未实现 |
| IOS-18 | Agent 长期记忆与本地召回 | ✅ | `AgentMemoryRecord` semantic/episodic 分层、confirmed/pending 生命周期、单条确认/编辑/删除、本地混合召回与 5 条/1200 字预算；设备端 embedding 和加密索引待后续评审 |
| IOS-19 | 专用 App 图标 | ✅ | `AppIcon.appiconset` + `ASSETCATALOG_COMPILER_APPICON_NAME`；模拟器主屏显示专用图标 |
| IOS-20 | 联网模型发现与兼容性白名单 | 🔄 | 开发完成（ADR 0008/0011）：HF 多路 search/metadata/config/tree、`ModelCompatibilityChecker`、动态 manifest、空间门控、流式 SHA-256；真实下载待真机 |
| IOS-21 | 显式联网检索工具 | 🔄 | 开发完成（ADR 0009）：默认关闭，Tavily Key 入 Keychain，检索上下文/来源注入 UI，失败降级本地；真实网络与回答引用待真机 |
| IOS-24 | 安装事务、残留修复与生成看门狗 | ✅ | `ModelStoreManager` staging + 原子提升、`InstallHealth`/残留清理、修复下载、`OutputLengthPlanner`、推理状态与 60s/45s 无进展超时；56 项 Swift 测试和 iOS Simulator 构建通过，真实 MLX 长输出待真机 |

## 本机验证命令（含沙盒环境注意事项）

```bash
# Swift 域层测试（本机 SwiftPM 沙盒与 ~/.cache 受限时使用以下参数）
cd edge-assistant/ios
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/eac-clang-cache \
  swift test --disable-sandbox \
  --cache-path /private/tmp/eac-cache \
  --manifest-cache local \
  --scratch-path .build

# JS 原型测试（未改动，回归用）
cd edge-assistant && npm test

# 浏览器原型
cd edge-assistant/prototype && python3 -m http.server 4173

# 构建 iOS App（需要 CoreSimulatorService，沙盒环境下需提权执行）
cd edge-assistant
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project EdgeAssistant.xcodeproj -scheme EdgeAssistant \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/edge-assistant-dd \
  -clonedSourcePackagesDirPath /private/tmp/edge-assistant-pkgs \
  -skipMacroValidation build

# Xcode 若提示 Metal Toolchain 缺失，先执行一次：
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -downloadComponent MetalToolchain

# 模拟器安装运行 + DEBUG 端到端自动对话
xcrun simctl install booted /private/tmp/edge-assistant-dd/Build/Products/Debug-iphonesimulator/EdgeAssistant.app
xcrun simctl launch booted com.startthree.edgeassistant --auto-chat
```

```bash
# 模拟器截图（本轮 IOS-13 内置链路回归）
xcrun simctl io booted screenshot /private/tmp/edge-assistant-ios13-final-baseline.png

# 模拟器商店界面（本轮 IOS-23 回归）
xcrun simctl install booted /private/tmp/edge-assistant-dd/Build/Products/Debug-iphonesimulator/EdgeAssistant.app
xcrun simctl launch booted com.startthree.edgeassistant --open-store
xcrun simctl io booted screenshot /private/tmp/edge-assistant-ios23-store-regression.png
```

## 设计与实现的已知偏差

1. `BundledAssetCatalog` 目前用确定性模拟字节 + 真实 SHA-256；这是内置开箱默认链路。IOS-13 已为商店模型新增真实 MLX 目录链路，后续替换内置模拟包时不改变 `AutoInstaller` 接口。
2. Mock 引擎的取消通过消费任务取消传播（`onTermination` → 内部 `Task.cancel()`）；测试注入真实 `Task.sleep` 保证取消发生在流式过程中。
3. `ThermalHysteresisController` 使用注入时间戳/时钟，不启动后台计时器；恢复检查由下一次热通知或回 active 的主动刷新触发。系统不会在高热消失时主动发通知，这符合“避免隐式定时器”的实现边界。
4. App 默认引擎是内置模拟资产的 Mock；商店文本 MLX 模型激活后替换为 `MLXInferenceEngine`，`mlx-vlm` 资产替换为 `MLXVisionLanguageEngine`。商店列表也提供“内置演示模型”显式切回 Mock。AppModel 的 `hasNPU = true` 假设 iOS 17+ 支持机型均含 Neural Engine。
5. `--auto-chat` 启动参数是 DEBUG-only 端到端验证钩子（`#if DEBUG`），Release 构建不含。
6. `mlx-community/gemma-4-e2b-it-4bit` 的 `gemma4` 架构已进入 `supported` 且工厂会选 VLM，但**尚未用真实权重验证**；其图像输入未实现，当前只承诺文字 chat 路径。
7. `MiniCPM-V 4.7 35B-A3B` 显示 `unsupported`，不能下载；`MNN-Pocket-0.3B` 显示 `requiresConversion`，不能直接部署。
8. Agent 会话/记忆已使用 AES-GCM 密文 SQLite，并进入 semantic/episodic 分层与 confirmed/pending 生命周期；第一阶段仍是整包 records 模型和确定性本地字符/词召回，不做明文索引、云端 embedding 或深层同义理解。联网检索只在用户开启后发起，检索失败不中断本地回答。
9. ADR 0011 使用与 MLX Swift LM 3.32 对齐的静态架构白名单，并先要求 `mlx-community` / `mlx` tag / `-mlx` 布局标记；没有动态读取第三方库内部 registry。搜索最多探测 12 个候选，请求空闲超时 8 秒。
10. 商店 manifest 解析会在主源失败且存在 `mirrorBase` 时回退镜像；这不等同于 HTTP Range 断点续传。用户取消下载保留已完成且校验通过的文件，重新下载会跳过这些文件，未完成文件重新下载。
11. 大文件下载走镜像重定向；请求与资源超时均为 7 天。当前进度按“当前文件已接收字节 / 清单总字节”估算，不显示逐文件标题。
12. iOS 模拟器可以下载并安装 MLX 权重，但 MLX 的 Metal Device 初始化在模拟器可能直接 abort；App 当前在模拟器激活 MLX 前提示“请在 iPhone 真机激活”，避免退出。
13. 大文件 SHA-256 是 async 分块摘要并周期 yield；下载任务为 utility 优先级。`ModelMemoryGate` 预留 1.5GB 上下文/Metal buffer，是保守防 SIGKILL 阈值，最终仍需真机基准校准。

## 最新修复：IOS-22 模型安装与激活预检

| ID | 任务 | 状态 | 说明 |
|---|---|---|---|
| IOS-22 | 下载/激活模型结构预检 + 真实容器预热 | ✅ | 修复真机“激活成功但首聊 JSON parsing failed”；当前 51 项 Swift 测试与 iOS Simulator 构建全绿；真实多模型输出仍需真机验收 |

**多模态与语音边界**：文件附件未实现；图片输入未实现（VLM 后端目前仅文字）；ASR/TTS/语音通话未实现；语音领域状态机已在域层设计。

## 最新修复：IOS-23 运行时感知模型发现

| ID | 任务 | 状态 | 说明 |
|---|---|---|---|
| IOS-23 | MLX registry 对齐 + 搜索并行化 + 下载/激活状态 | ✅ | 修复 Gemma 点击无反馈与刷新长时间转圈；51 项 Swift 测试、JS 24 项与 iOS Simulator 构建通过 |

IOS-23 行为要点：Gemma 4 E2B 在商店中保持可点击；点击后先显示“正在解析模型清单…”，再进入分文件进度，下载完成自动激活并显示“正在激活…”。硬件档位只以“高于本机推荐档位”提示，不会静默禁用 `supported` 模型。主源 manifest 不可达/为空时，已配置 `mirrorBase` 的模型直接回退 `hf-mirror`，避免点击后停留在解析阶段。MiniCPM-V 4.7 与 MNN Pocket 仍分别显示不支持/需转换。

IOS-23 易用性修复：解析/下载失败、百分比进度和“取消下载”都显示在对应模型行内，不再把“解析模型清单失败”抛到页面顶部；大文件下载改用 `URLSession.downloadTask`，请求/资源超时均为 7 天，避免镜像长连接中途被误杀。已修复 Safetensors 标量张量（`shape: []`）误判，Gemma 4 E2B 3.3GB 权重可完成下载/校验/入库。

IOS-23 真机内存护栏：iPhone 14 console 复现显示下载/校验已全部完成，但激活 3.6GB Gemma 时系统 signal 9。新增 `ModelMemoryGate`，用 `os_proc_available_memory()` 加 1.5GB 预留评估 MLX 加载；不足时显示内存错误并阻止激活。复测 App 不再退出。Gemma 4 E2B 在 iPhone 14 只完成下载/入库，不承诺可推理；真实 MLX 输出需更大内存设备或更小模型。

## 最新优化：IOS-23b 商店可发现性与 UI

| ID | 任务 | 状态 | 说明 |
|---|---|---|---|
| IOS-23b | 多路量化搜索 + 结果排序 + 商店/聊天 UI 优化 | ✅ | 51 项 Swift 域层测试与 iOS Simulator 构建通过；真实多模型下载/推理仍待真机 |

行为要点：普通搜索词（如 `qwen`）自动扩展 `mlx-community` 和 4bit/8bit 查询；候选去重后并行探测 12 个。结果优先显示 `supported`，同档按体积升序。每张模型卡显示下载体积、内存负担和本机风险；“推荐轻量 MLX 模型”一键搜索。聊天页新增模型商店直达按钮，输入框最多展开 5 行，发送改为图标按钮，并在热停顿时明确显示“输入会保留”。

## 最新修复：IOS-23c 镜像探测与 chat template

| ID | 任务 | 状态 | 说明 |
|---|---|---|---|
| IOS-23c | config/manifest/权重镜像回退 + 完整模型清单 + prompt 去重 | ✅ | 修复“全部待检查、下载不了”和 Llama 可能只复述身份提示的问题；51 项 Swift 测试与 iOS Simulator 构建通过 |

修复要点：未激活的旧安装模型提供“修复清单”入口，可重新解析 manifest 并补齐缺失文件。主源 `config.json` 非 2xx/超时后立即尝试 `hf-mirror.com`；远程 supported 候选现在自带镜像 `mirrorBase`，manifest 与权重都能镜像下载。静态 supported 模型不再硬编码四个文件，而是解析完整远端 manifest，确保 `chat_template.jinja` 等必需文件不缺。`AgentContextBuilder` 不再把身份指令重复放进 user prompt，引擎只在 system 消息中声明身份，降低小模型复述系统提示的概率。语音通话仍未开始，原因已在 IOS-17 记录：缺麦克风/AEC/VAD/ASR/TTS/播放/打断管线，不是 1B 文本模型太笨。

## 最新完成：IOS-15 安全持久化底座

| ID | 任务 | 状态 | 说明 |
|---|---|---|---|
| IOS-15 | 加密数据库 + Keychain 密钥管理 | ✅ | 56 项 Swift 测试、JS 24 项与 iOS Simulator 构建通过 |

行为要点：SQLite 只保存 `agent_blob` 中的 AES-GCM combined ciphertext，不保存可读消息或事实字段；密钥错误或密文篡改会停止加载。旧 `agent-memory.json` 和 `conversation.json` 首次读取时迁移进 SQLite 并删除。Agent 数据密钥与 Tavily Key 使用不同 Keychain 条目，均为 `WhenUnlockedThisDeviceOnly`。Agent 设置新增“删除 API Key 并关闭检索”；“清除记忆与会话”先删除数据密钥，再清空密文和旧 JSON 残留，旧备份不再可恢复。后续分层/向量召回见 ADR 0013 的评审边界。

## 最新完成：IOS-18 第一阶段

| ID | 任务 | 状态 | 说明 |
|---|---|---|---|
| IOS-18 | Agent 长期记忆与本地召回 | ✅ | 56 项 Swift 测试、JS 24 项与 iOS Simulator 构建通过 |

行为要点：`AgentMemoryRecord` 区分 semantic / episodic。显式“记住……”生成 confirmed episodic；身份、偏好、职业推断生成 pending semantic。pending 只出现在 Agent 设置，不参与 recall 和 prompt；用户可确认、忽略、编辑或删除单条记忆。`AgentMemoryRecall` 使用本地字符/词特征、IDF、21 天时间衰减和类型权重排序，再按最多 5 条 / 1200 字装箱；无匹配时回退最近 confirmed。Prompt 明确标注“仅已确认，仅供个性化回答”。设备端 embedding、加密索引、主题分区和来源审计是后续阶段。

## 下一步（按序）

1. **IOS-13/20/23b 真机验收**：联网搜索 `qwen`、`gemma`、`smollm`，优先安装轻量 supported 模型，验证解析/下载/自动激活状态、分片下载、首 token、输出、打断、取消与温控上限；确认 MiniCPM 与 MNN 按预期不可直接部署。
2. **Agent 能力真机验收**：重启验证会话/记忆恢复；开启 Tavily 后验证来源 UI、引用与检索失败降级。
3. **IOS-14**：真机三档基准测试（依赖 IOS-13 真机验收）。

## 会话恢复检查单

- [x] `swift test`（上方命令）56 项全绿？
- [x] `npm test` 24 项全绿？
- [x] 本文件“任务清单”状态与实际代码一致？
- [x] `docs/design-ios.md` 验收清单与实现一致？
- [x] 完成本次任务后更新：本文件（状态、最后更新、下一步）→ `docs/design-ios.md`（如有设计变化）→ `README.md` / `docs/HANDOFF.md` / `docs/roadmap.md`。
