# Edge Assistant iOS 详细设计

## 1. 目标与范围

本文档是 iOS 端的实现级设计，约定与 `docs/design.md` 的产品设计、`docs/adr/0004` 的技术选型一致。

**当前阶段（M1-iOS）范围**：域层 Swift Package、推理引擎协议、Mock 与 MLX 真实文字推理后端、模型资产自动装载（安装即内置）、模型商店管理链路、核心逻辑单元测试。

**非目标（后续里程碑）**：语音/视频管线、加密数据库落地、App Store 发布。真实推理范围由 ADR 0006 明确为 MLX 文字聊天；llama.cpp / Core ML 仅作为后续备选评测。

## 2. 工程结构

```text
ios/
├── Package.swift                     # EdgeAssistantCore 域层包
├── Sources/EdgeAssistantCore/
│   ├── Tiers.swift                   # 档位、机型分级（DeviceProfile）
│   ├── Pipeline.swift                # 延迟预算、语音状态机、打断动作
│   ├── ModelAsset.swift              # 资产模型、元数据校验、SHA-256 校验
│   ├── ModelRegistry.swift           # 资产注册与档位选择
│   ├── ModelAssetManager.swift       # 安装保护/单步回滚（actor）
│   ├── BundledAssets.swift           # 自带资产目录 + 自动装载编排器
│   ├── InferenceEngine.swift         # 推理协议 + Mock 后端（流式/取消/指标）
│   ├── MLXInferenceEngine.swift      # MLX Swift LM 真实文字推理适配层
│   ├── InferenceEngineFactory.swift  # 按资产位置/格式选择 Mock 或 MLX
│   └── Thermal.swift                 # ProcessInfo 热状态映射与降级动作
└── Tests/EdgeAssistantCoreTests/     # 与 JS 原型测试一一对应
```

当前 App target（M1.5）只包含：SwiftUI 视图、系统服务粘合（热通知、DEBUG 验证钩子）、依赖注入。语音相关的麦克风服务仍在 M2。

### 2.1 App 壳设计（M1.5，已实现）

`EdgeAssistant.xcodeproj`（仓库根目录）包含单一 App target，源码目录 `ios/EdgeAssistantApp/` 通过 Xcode 文件系统同步组自动纳入：

| 文件 | 职责 |
|---|---|
| `EdgeAssistantApp.swift` | `@main` 入口；`.task { await model.autoProvision() }` 实现启动即自动装载 |
| `AppModel.swift` | `@MainActor` 可观察状态：装载状态机（provisioning/ready/failed）、会话消息、流式发送、打断、热档位展示与推理门控 |
| `ChatView.swift` | 聊天界面：模型状态头、消息列表、输入栏、发送/打断按钮 |
| `Assets.xcassets/AppIcon.appiconset` | 专用 App 图标：本地边缘计算 + Agent 会话视觉 |

关键语义：

1. **启动序列**：`DeviceProfile` 由 `ProcessInfo.physicalMemory` 推导（iOS 17+ 支持设备均含 Neural Engine，`hasNPU = true`）；`AutoInstaller.installForTier` 自动执行，失败显示“重新校验”，成功显示“内置模型已就绪”。
2. **聊天直接调用内置模型**：`generateStream` 逐 token 更新最后一条助手消息；`done` 指标（首 token 延迟/时长）以系统消息展示。
3. **打断**：输入栏在流式期间切换为停止按钮，点击即 `Task.cancel()` → 引擎记录 `cancelled` 指标 → 消息标记“（已打断）”，与设计 §5.1 打断规则一致（M1.5 阶段只取消推理，TTS 属 M2）。
4. **会话为本地加密持久化**：会话和长期事实已迁移到 Application Support 下的 SQLite；写入前使用 AES-GCM 加密，密钥保存在 Keychain（见 ADR 0013 存储切片）。
5. **热状态展示**：`AppModel` 监听系统热通知，头部展示当前热档位；升级立即生效，恢复逐级迟滞（见 §7）。`critical` 时暂停发送但保留输入框可编辑。
6. **DEBUG 真机验收钩子**：`--auto-chat` 触发一次自动对话；`--auto-interrupt-ms <ms>` 可在其后定时调用与停止按钮相同的 `interrupt()`，用于真机验证 MLX 取代语义。两个钩子都只在 DEBUG 生效。

### 2.2 产品身份与 Agent 记忆边界

App 图标使用仓库内 `AppIcon.appiconset`，视觉方向为深色端侧底座 + 白色对话气泡 + 本地神经网络节点；不使用文字，保证小尺寸识别度。Xcode target 设置 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`。

IOS-15 安全持久化底座与 IOS-18 第一阶段记忆生命周期已实现：

1. 会话与身份/偏好事实已持久化到 AES-GCM 加密的 SQLite，旧 JSON 首次读取时迁移并删除，重启可恢复。
2. Agent 数据密钥与 Tavily API Key 分别保存在 Keychain，均为 `WhenUnlockedThisDeviceOnly`。
3. 用户可保存、更新和删除检索 API Key；删除会同时关闭联网检索开关。
4. “清除记忆与会话”会先销毁数据密钥，再清空 SQLite 行与旧 JSON 文件；旧数据库备份不再可解密。
5. `AgentMemoryRecord` 区分 semantic / episodic 和 confirmed / pending；显式“记住”直接确认，推断候选只在设置页等待用户确认。
6. Agent 设置支持单条确认、忽略、编辑、删除；pending 不参与召回和 prompt。
7. `AgentMemoryRecall` 用本地字符/词特征、IDF、时间衰减和类型权重混合排序，再按最多 5 条 / 1200 字预算注入。

图标验收：1024px 资产已编译进 `Assets.car`；iOS Simulator 主屏显示深色对话 + 本地神经网络图标，不再是默认占位图。

### 2.3 可靠安装与生成看门狗（IOS-24）

模型商店目录分两层：`.staging/<id>` 是可续传工作区，`<id>` 只保存通过结构、大小与 SHA-256 校验的完整安装。App 启动和商店刷新时计算 `InstallHealth`：有 metadata 且关键文件完整为 `installed`；有 metadata 但 manifest 文件缺失/损坏为 `incomplete`；无 metadata 目录为 `residual`。用户可显式清理最终残留或中断 staging，下载入口对 incomplete/residual 统一为“修复下载”，不再出现有残留但无法重新安装的死锁。

聊天发送后会显示推理准备状态。系统解析明确长度意图（例如 800 字），normal 档允许最多 2000 字，warm/hot 继续保留 120/90 字降级；MLX token 预算按目标长度上浮。推理在 60 秒无首 token 或 45 秒无增量时抛出 `EngineError.timeout(stage)`，UI 显示可读错误。因上限截断时明确提示“已达本次安全上限”。

## 3. 模块映射（JS 原型 → Swift → iOS 系统能力）

| 原型 (JS) | Swift 域层 | iOS 系统能力 |
|---|---|---|
| `classifyDevice` | `DeviceProfile.tier` | `ProcessInfo.physicalMemory`（M2 接入真机值） |
| `planPipeline` | `PipelinePlanner.plan` | — |
| 语音状态机/打断 | `ConversationStateMachine` / `Interrupt` | AVAudioSession（M2） |
| `model-registry` | `ModelRegistry` + `ModelAssetValidator` | — |
| SHA-256 校验 | `SHA256Verifier`（CryptoKit） | — |
| `createModelAssetManager` | `ModelAssetManager`（actor） | 文件保护 API（M2） |
| `asset-installer` | `BundledAssetCatalog` + `AutoInstaller` | App Bundle 资源；ODR（后续） |
| `inference-engine` | `InferenceEngine` 协议 + `MockInferenceEngine` | `MLXInferenceEngine`（ADR 0006） |
| 温控降级（设计 §5.7） | `ThermalMapper` | `ProcessInfo.thermalState`、热通知 |

## 4. 推理引擎协议

```swift
public protocol InferenceEngine: AnyObject {
    func load(_ asset: ModelAsset) throws   // 要求已通过完整性校验
    func unload()
    func status() -> EngineStatus           // unloaded / ready + 最近指标
    func generateStream(_ request: InferenceRequest)
        -> AsyncThrowingStream<InferenceEvent, Error>
}
```

语义（与 `docs/api/inference-engine.md` 对齐）：

1. `ready` 状态才允许推理；资产能力不含当前模式直接抛错，不静默降级。
2. 流式事件：`token(text:firstTokenMs:outputChars:)` 与 `done(metrics)`。
3. 取消 = `Task` 取消：流内部检查 `Task.isCancelled`，取消时记录 `cancelled: true` 指标并以 `CancellationError` 结束；上层同时停 TTS、丢帧（M2）。
4. 后端适配：MLX / llama.cpp 各实现一个 `InferenceEngine`，平台差异只存在于适配层内部。

## 4.1 MLX 文字推理后端（ADR 0006）

### 依赖与加载

`EdgeAssistantCore` 锁定引入 MLX Swift LM `3.32.x`（当前 `3.32.3`），以及 `swift-huggingface`、`swift-transformers`。该版本 manifest 要求 Swift Tools 6.2 和 iOS 17+ / macOS 14+；因此包和 App target 的 deployment target 提升到 iOS 17，同时 Swift 源码语言模式保持 v5。真实引擎持有从 `ModelAsset.localDirectory` 加载的 `ModelContainer`：

```swift
LLMModelFactory.shared.loadContainer(
    from: localDirectory,
    using: #huggingFaceTokenizerLoader()
)
```

加载是异步操作；`InferenceEngine.load(_:)` 保持同步协议，`MLXInferenceEngine` 在生成前完成懒加载并缓存容器。加载失败进入 `EngineStatus.lastError`，随后生成抛错；不得回退 Mock 或云端。

### Prompt 与生成

- `InferenceRequest.mode` 必须包含在资产能力中；IOS-13 只允许 `.chat`。
- 空白 prompt 拒绝。
- 结构化输入为 `.system(...)` + `.user(request.prompt)`；`AgentContextBuilder` 只注入任务相关上下文（记忆、历史、检索结果和当前问题），不再把身份指令重复塞进 user 消息，避免小模型复述系统提示。
- 静态 supported 模型也通过远端 manifest 解析必需文件，包括 `chat_template.jinja`、tokenizer 和 generation 配置；不能只用四个硬编码文件，否则部分 Llama/Qwen 仓库会缺 chat template，导致模型退化成普通文本补全。
- 已安装但未激活的旧模型提供“修复清单”入口；修复会重新解析 manifest。若新必需文件缺失，Store 层先移除旧目录再重建，正在使用的模型禁止自动删除。
- `container.prepare(input:)` 后调用 `container.generate(input:parameters:)`，消费 `Generation` 流式事件。
- `.chunk` 转成 `InferenceEvent.token`；首个 chunk 前记录 first-token 延迟；`.info` 忽略，`.toolCall` / `.rejectedToolCall` 按不支持能力拒绝，不伪造工具调用。
- 生成完成或取消都记录 `InferenceMetrics`。

### 输出上限与取消

- `request.maxOutputChars` 是产品级字符预算；MLX `maxTokens` 用 `max(16, maxOutputChars / 2)` 近似，避免中英文 token/字符差异导致空回复。大文件下载的请求/资源超时均为 7 天，避免镜像长连接中途被误杀；主源失败回退镜像。
- 流取消通过 `continuation.onTermination` 取消内部 `Task`；MLX 循环随 Swift task cancellation 退出，记录 `cancelled: true` 后以 `CancellationError` 结束。

### 后端选择

`InferenceEngineFactory.make(for:)`：

1. `ModelAsset.localDirectory != nil` 且 `ModelAsset.format` 以 `mlx` 开头：返回 `MLXInferenceEngine`。
2. 其他资产：返回 `MockInferenceEngine`，继续保证测试和内置模拟资产无网络可用。
3. 上层不再直接构造具体引擎，只在初始化注入默认 Mock 引擎；激活模型时通过工厂替换实例。

## 4.2 联网模型发现与 MLX/VLM 后端（ADR 0008）

- HuggingFace 搜索/详情只产生候选；`ModelCompatibilityChecker` 用 `config.json` 的 `model_type` 与后端 registry 判定可执行性。
- 支持状态分为 `supported`、`requiresConversion`、`unsupported`；只有 `supported` 显示部署按钮。
- 文件树解析下载 MLX 所需的配置、tokenizer/processor、chat template、权重 index 与全部分片；权重用流式 SHA-256 校验。
- `MLXInferenceEngine` 按 `format` 选择 `LLMModelFactory` 或 `MLXVLM.VLMModelFactory`。VLM 本阶段仅支持纯文字对话；图像输入是后续任务。

### 4.2.0 运行时感知的模型发现（ADR 0011）

- 先判定权重布局：只有 `mlx-community/*`、`mlx` 相关 tag 或 `*-mlx` 仓库才进入 runtime registry 架构检查。
- 架构判定与 MLX Swift LM 3.32 的 LLM/VLM registry 对齐；不在 registry 内不提供下载。MNN/GGUF/ONNX/原始 transformers 一律显示“需转换”，不假装可执行。
- HuggingFace catalog 客户端使用 8 秒请求 / 20 秒资源超时；文本与视觉搜索并行，最多并行探测 12 个候选。单个候选探测失败只降级为“待检查”，不拖垮整次搜索；搜索结束后 loading 必然复位。
- 搜索会用“用户输入 + `mlx-community` 前缀 + `4bit/8bit` 变体”扩展成多路 HuggingFace 请求；候选按仓库去重，并优先返回 supported。普通输入也能发现量化端侧模型，而不是只返回通用搜索的第一页。
- 候选探测必须镜像回退：主源 `config.json` 请求失败或返回非 2xx 时，立刻尝试 `hf-mirror.com` 的同一文件；主源可达时不得额外请求镜像。远程候选的动态 manifest 和权重下载也配置同一镜像前缀，避免“搜索得到、探测失败、下载不了”。
- 动态 manifest 解析支持镜像回退：主源 tree 为空/不可达且模型配置了 `mirrorBase` 时，改用镜像 tree API，并直接生成镜像文件 URL；不在每个权重下载阶段重复等待主源超时。
- 下载错误按模型行内展示，并提供“取消下载”入口；下载进度显示百分比。全局错误只保留搜索/激活类提示。
- 大文件权重使用 `URLSession.downloadTask` 写入目标目录，避免长连接流读取中途截断；下载完成后仍执行 Safetensors 结构校验。Safetensors 标量张量的 `shape: []` 合法。
- 大文件 SHA-256 使用 cooperative async 分块摘要并周期 yield；下载任务使用 utility 优先级，避免校验 3GB 权重时占用过高 CPU。
- 激活前执行 `ModelMemoryGate`：`os_proc_available_memory()` + 权重体积 + 1.5GB 上下文/缓冲预留。不足时直接提示换小模型，避免 iOS 用 SIGKILL 终止 App。
- 商店对 ≤2GB、2–4GB 和 >4GB 权重分别显示轻量/中量/重量内存负担；结果优先按可运行、体积升序排序。内存护栏在激活阶段仍然保留，UI 只预筛推荐，不绕过加载验证。
- iOS 模拟器允许下载和安装 MLX 权重，但激活 MLX 前会提示真机执行，避免 MLX Metal Device 初始化在模拟器 abort 导致 App 退出。
- “下载并部署”分别展示解析清单、下载和自动激活状态；下载完成由 App 自动调用激活。设备档位只提示风险，不静默禁用 supported 模型。
- 用户取消下载保留已完成且通过结构/大小/摘要校验的文件；重新下载会跳过这些文件。当前不是 HTTP Range 断点续传，未完成分片会重新下载。

### 4.2.1 模型安装与激活预检（ADR 0010）

- 下载器对 `.json`、`.safetensors`、`.jinja` 做结构化校验；结构、大小或摘要失败时可使用既有镜像回退。
- `activate(id)` 预检已安装目录必需的 `config.json`、`tokenizer.json` 和至少一个 safetensors，并拒绝截断/HTML/LFS pointer 伪装文件。
- `InferenceEngine.prepare()` 在激活阶段加载真实 MLX/VLM 容器；Mock 立即通过。激活失败时保留旧引擎，避免“看似已激活、首聊失败”。
- 当前边界：文件附件、图片输入、ASR/TTS、语音通话均未实现；语音状态机只是领域层设计。

## 4.3 显式联网检索与 Agent 记忆（ADR 0009）

- 默认完全离线。开启联网检索后，App 层先执行搜索，再把带 URL 的结果注入 prompt；本地模型和推理引擎不直接联网。
- 搜索 API Key 使用 Keychain `ThisDeviceOnly` 存储；来源消息展示 title/URL，检索失败降级为本地回答。
- 用户消息提取长期记忆事实，会话与事实持久化到本地 JSON；每次请求注入最近消息和相关事实，重启后可召回。
- 当前实现使用 AES-GCM 密文 SQLite；IOS-18 第一阶段已在其上扩展分层记忆、本地混合召回和细粒度生命周期。设备端 embedding 与加密索引待后续评审。

## 4.4 语音通话边界（IOS-17 / M2，未开始）

- 语音通话不是当前 1B 文本模型“能力不足”的问题，而是缺少独立音频管线：麦克风采集、AEC、VAD、流式 ASR、LLM 流式输出、流式 TTS、播放和全双工打断。
- M1 的 `ConversationStateMachine` 和延迟预算只是领域模型；没有 AVAudioSession、麦克风权限、播放路由和打断停播实现。
- 首版语音入口必须在文字链路真机验收后启动，优先使用系统 Speech/AVSpeech 合成做基线，再评估本地小 ASR/TTS；目标是 P50 < 1.2s、打断停播 < 80ms。
- 小内存设备可以先开放“语音听写 + 文字回复”，不是完整语音通话。

## 5. 安装即内置（iOS 落地）

1. **交付**：当前档位模型以 App Bundle 资源随 App 安装落盘（MVP）；后续大模型迁到 On-Demand Resources，`BundledAssetCatalog` 是唯一读取入口，切换不影响上层。
2. **启动序列**：App 启动 → `Task` 中执行 `AutoInstaller.installForTier(tier)` → SHA-256 校验（CryptoKit）→ `ModelAssetManager.install`（失败不改变已激活资产）→ `engine.load`。全程无网络、无用户操作。
3. **校验失败**：状态展示错误 + “重新校验”入口；本地指标记录。
4. **热更新**（后续）：后台下载新资产包 → 校验 → 激活，失败走单步回滚，与首次装载共用机制。

## 5.2 应用内模型商店（ADR 0005，已实现管理链路）

### 目录（Catalog）

静态目录列出经过筛选的开源模型，字段：`id`、`displayName`、`source`（HF 仓库）、`format`（`mlx-4bit` 等）、`parameters`、`sizeBytes`、`license`、`minTier`、`capabilities`、`files: [RemoteModelFile]`（path + resolve URL + 可选 sizeBytes/sha256）。首批目录：

| 模型 | 来源 | 量化 | 体积 | minTier |
|---|---|---|---|---|
| Qwen2.5-0.5B-Instruct | mlx-community | 4-bit | ~0.4GB | entry |
| Qwen2.5-1.5B-Instruct | mlx-community | 4-bit | ~1.0GB | mainstream |
| Llama-3.2-1B-Instruct | mlx-community | 4-bit | ~0.7GB | entry |
| Qwen3-0.6B | mlx-community | 4-bit | ~0.4GB | entry |

### 下载与安装流程

1. 用户在“模型商店”选择模型 → `ModelStoreManager.download`。
2. 多文件顺序下载（`URLSessionModelDownloader`，AsyncBytes 流式写盘，256KB 缓冲），进度 =（已完成文件 + 当前文件分数）/ 文件总数；可取消。
3. 当前下载器按文件原子写盘；进入某文件下载前会重建目标文件。部分模型目录只有在全部文件成功并写入 metadata 后才可见。
4. 每文件校验：有 `sha256` 用 CryptoKit 校验，有 `sizeBytes` 校验大小；任一失败清理整个目录，不产生半安装状态。
5. 全部通过后写 `metadata.json`（完整目录快照 + 安装时间 + 聚合 SHA-256）。

### 激活与切换

`activate(modelID)` 从 metadata 构建 `ModelAsset`（sha256 = 聚合摘要，capabilities = 模型能力，localDirectory = 安装目录）→ `InferenceEngineFactory.make(for:)` → `load`。自带模型与商店模型共用同一引擎契约，切换即换资产。激活中的模型禁止删除。

### 存储与边界

- 位置：`Application Support/EdgeAssistant/models/<model-id>/`；删除即删目录。
- 下载需显式触发（大文件），显示进度并支持取消；当前写入 `.staging/<id>`，全部结构/大小/SHA 校验后原子提升为 `<id>`。
- 取消/失败保留 staging 中已完整文件，重试幂等复用并覆盖坏文件；无 metadata 或 metadata 损坏残留与中断 staging 可在商店显式清理。
- **能力边界（透明）**：`format` 以 `mlx` 开头且已有安装目录的商店模型激活后使用 `MLXInferenceEngine`；无安装目录的内置模拟资产继续使用 Mock。商店模型能力标签仅含 `chat`（语音/视频待对应管线）。

## 6. 数据与安全（实现排期见进度文档）

- 数据库：系统 SQLite 保存 AES-GCM 密文（ADR 0013）；不引入 SQLCipher，也不把消息/事实明文写入数据库。
- 密钥：Keychain（`kSecClassGenericPassword`，`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`）。清除 Agent 数据先销毁数据密钥，再删除密文；检索 API Key 可独立保存、更新和删除。
- 音频/视觉中间数据只在内存，不落盘。
- 日志：不记录用户消息原文，只记录事件类型与指标（`os.Logger`，private 级别脱敏）。

## 7. 温控与功耗（iOS 映射）

| `ProcessInfo.thermalState` | 设计档位 | 动作（设计 §5.7） |
|---|---|---|
| `.nominal` | normal | 无 |
| `.fair` | warm | 缩短回复上限；视觉 1–2fps → 0.5fps |
| `.serious` | hot | 停用视觉；语音回复再缩短；关高频 TTS 缓存 |
| `.critical` | critical | 暂停推理，提示过热，保留文字输入 |

恢复逐级迟滞（每级 ≥ 60s）；监听 `ProcessInfo.thermalStateDidChangeNotification` 驱动状态迁移。

### 7.1 IOS-16 热状态接入

- **纯域层控制器**：`ThermalHysteresisController` 只依赖 `ProcessInfo.ThermalState`、`ContinuousClock.Instant` 和注入的 `ThermalClock`，不持有 UIKit/SwiftUI 类型，可单元测试。
- **迁移语义**：
  - 首次观测使用系统当前 `ProcessInfo.thermalState` 初始化，不假设一定从 `normal` 开始。
  - `ThermalMapper.level` 得到目标档位；目标档位升高时立即迁移，并重置当前档位计时。
  - 目标档位降低时必须满足当前档位已持续 ≥ 60s，且每次调用最多恢复一级；中间跳变先落到一级，等待下一个 60s 再继续恢复。
  - 恢复过程中若热状态再次升高，立即升级并重置计时。
- **App 壳**：`AppModel` 使用 `NotificationCenter.notifications(named: ProcessInfo.thermalStateDidChangeNotification, object: ProcessInfo.processInfo)` 触发刷新；启动和回到 active 都会先读一次当前状态，补偿 App 在后台错过的事件。热档位变化写入系统消息，头部使用颜色 + 文本展示。
- **推理映射**：
  - `normal`：使用当前默认输出上限。
  - `warm`：缩短聊天回复上限到 120 字。
  - `hot`：进一步缩短到 90 字；视觉禁用语义保留在 `ThermalDegradePlan`，M2 语音/视频管线接入时消费。
  - `critical`：暂停推理；阻止新发送，已有生成按既有打断语义立即取消；输入框保持可编辑。
- **边界**：通知只提供事件，不携带新热值；刷新时读取当前 `ProcessInfo.thermalState`。控制器不启动计时器，时间戳由调用方传入，避免后台任务和隐式定时器；恢复实际发生依赖下一次热通知或 App 回 active 时的主动刷新。为保证迟滞可验证，测试注入固定时钟。

## 8. 并发模型

- `ModelAssetManager`、后续数据库访问：actor 隔离。
- 推理流：`AsyncThrowingStream` + 内部 `Task`；取消即释放推理上下文（Mock 实现为完成流；MLX 为中断解码循环）。`ModelContainer` 是 actor，`MLXInferenceEngine` 用 `any InferenceEngine` + 状态锁封装生命周期，不跨层暴露 MLX 类型。
- UI 层（M2）：`@MainActor`；域层不持有 UI 类型。

## 9. 权限（iOS Info.plist 对应）

| 权限 | Key | 拒绝表现（同设计 §7） |
|---|---|---|
| 麦克风 | `NSMicrophoneUsageDescription` | 仅文字模式 |
| 摄像头 | `NSCameraUsageDescription` | 视频功能禁用 |
| 屏幕录制 | Broadcast Extension（后续） | 屏幕理解禁用 |
| 通知 | UNUserNotificationCenter | 提醒降级 |

## 10. 测试与验收（M1-iOS）

- [x] 机型分级、档位能力与 JS 原型一致。
- [x] 语音状态机迁移与打断动作与 JS 原型一致（打断必取消推理）。
- [x] 资产元数据校验、SHA-256 校验、注册表按档位选最新。
- [x] 安装失败保护与单步回滚（actor）。
- [x] 自动装载编排器：成功链路、损坏资产不改已激活资产、进度事件。
- [x] Mock 推理流：能力门控、流式 token/done、取消记录指标。
- [x] `swift test` 全绿（36 项）。纯域用例不读取网络或真实权重；MLX/MLXVLM 依赖编译与包解析通过。

### IOS-13 MLX 文字推理验收

- [ ] 商店下载的 MLX 模型激活后走 `MLXInferenceEngine`，产生真实模型文本。
- [x] 无 `localDirectory` 的内置模拟资产仍走 Mock。
- [ ] 生成过程 UI 可流式渲染，打断能取消 MLX 解码。
- [ ] 完成事件包含首 token、总时长、输出字符；取消事件记录 `cancelled: true`。
- [x] 温控 `warm/hot` 的字符上限仍传到真实引擎；`critical` 阻止新发送并取消已有生成。
- [x] 依赖解析与 App 构建通过；无权重仓库提交。

> 真机验收：需在网络可达环境显式下载模型，确认 MLX 目录加载、流式输出、打断和指标。模拟器内 HuggingFace 下载超时属本机网络/镜像环境问题，不作为后端编译验收阻塞。

### IOS-20 模型发现与 MLX/VLM 验收

- [x] HuggingFace 搜索候选可解析为兼容性状态；blocked/requiresConversion 模型不触发文件下载。
- [x] `gemma4` 映射 `mlx-vlm` 且工厂选择 `MLXVisionLanguageEngine`。
- [x] `minicpmv4_7` 显示不支持；`taobao-mnn/MNN-Pocket-0.3B` 显示需转换。
- [x] 动态 manifest 包含权重 index/分片、tokenizer/processor/config；权重校验使用流式 SHA-256。
- [x] 下载前检查剩余空间；失败清理不改变已安装模型。
- [ ] 真机联网刷新后下载 Gemma 4 E2B，VLM 工厂加载成功并产生纯文字流式输出。
- [ ] 真机确认分片下载进度、打断/取消、磁盘门控和镜像回退。

### IOS-15 安全持久化验收

- [x] SQLite 原始字节不包含 transcript/facts 明文。
- [x] 旧 JSON 迁移进 SQLite 后删除。
- [x] AES-GCM 认证失败时不返回业务数据。
- [x] Agent 数据密钥与 Tavily Key 独立保存在 Keychain。
- [x] 设置页可保存、更新和删除检索 API Key。
- [x] 清除记忆与会话先销毁数据密钥，再删除 SQLite 密文。
- [x] 56 项 Swift 域层测试与 iOS Simulator 构建通过。

### IOS-18 分层记忆与召回验收

- [x] 显式“记住”生成 confirmed episodic。
- [x] 推断身份/偏好生成 pending semantic。
- [x] pending 不参与 recall 与 prompt。
- [x] 设置页支持单条确认、忽略、编辑、删除。
- [x] 混合召回包含词汇、时间和类型权重。
- [x] 工作记忆遵守 5 条 / 1200 字预算。
- [x] prompt 标注记忆类型与用途边界。
- [x] 记录 payload 仍为 AES-GCM 密文。
- [x] 56 项 Swift 域层测试与 iOS Simulator 构建通过。

### IOS-21 Agent 记忆与检索验收

- [x] 用户消息可提取姓名/偏好/记住指令；重复事实不重复保存。
- [x] 长期事实、最近历史和检索结果注入 prompt。
- [x] 会话与记忆跨启动恢复，UI 可清除。
- [x] 联网检索默认关闭；开启后检索词展示，来源消息带 URL。
- [x] 检索失败或无 Key 时降级为本地回答，不伪造来源。
- [ ] 真机验证 Tavily 网络请求、回复中的引用与 App 重启恢复。

### IOS-23 运行时感知发现验收

- [x] 非 MLX 布局（原始 transformers/GGUF/ONNX/MNN）判定 `requiresConversion`；MLX 布局再按 registry 白名单判定。
- [x] 搜索文本/视觉请求并行，最多探测 12 个候选；单候选失败只显示“待检查”，不阻断整次搜索。
- [x] Gemma 4 E2B 在模拟器商店中可点击；“解析清单 → 分文件进度 → 正在激活”状态可见。
- [x] 下载完成后自动激活；硬件档位低于推荐值时显示风险提示，不静默禁用 supported 模型。
- [x] 主源 manifest 不可达/为空时，配置了 `mirrorBase` 的模型回退到 `hf-mirror` 并直接使用镜像文件 URL。
- [x] iPhone 14 下载 Gemma 4 E2B 完成；激活前内存护栏阻断 3.6GB 模型，App 不再被系统 signal 9 杀掉。
- [x] 用户取消保留已完成文件，重新下载跳过已完成文件；HTTP Range 断点续传仍未实现。
- [ ] 真机联网刷新、下载 Gemma 4 E2B 并验证自动激活后的真实输出。

### IOS-16 热状态验收

- [x] 热档位升级立即生效；`ThermalDegradePlan` 与设计 §5.7 一致。
- [x] 当前档位持续不足 60s 时不恢复。
- [x] 持续超过 60s 后每次最多恢复一级；从 `critical` 恢复到 `normal` 需要多次迁移。
- [x] 恢复期间升级立即生效并重置迟滞计时。
- [x] App 壳监听系统热通知并展示当前热档位（正常档位不显示徽标，避免常驻噪声）。
- [x] `critical` 阻止发送并取消已有推理，同时允许输入框编辑。
- [x] `warm`/`hot` 将缩短后的输出上限传给推理请求。

### IOS-24 可靠安装与生成看门狗验收

- [x] 下载先进入 `.staging/<id>`；完整校验后原子替换/创建安装目录。
- [x] 校验失败不写入最终 `metadata.json`；取消保留 staging，重试跳过已完整文件。
- [x] `InstallHealth` 可区分 missing/installed/incomplete/residual；无 metadata/坏 metadata 残留与中断 staging 可枚举和清理。
- [x] 带 metadata 但缺关键文件的安装可重新下载修复。
- [x] “800 字”明确长度意图在 normal 档提升输出预算；warm/hot 仍分别限制 120/90 字。
- [x] MLX 生成有准备/生成状态、首 token 60s 和 token 间 45s 超时；超时/截断/空输出有系统提示。
- [x] 56 项 Swift 域层测试与 iOS Simulator 构建通过；真实 MLX 长输出仍待真机验收。
