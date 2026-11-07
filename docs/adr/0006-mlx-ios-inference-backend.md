# ADR 0006: iOS 真实文字推理采用 MLX Swift LM

## 状态

已接受

## 背景

IOS-8 已用 `MockInferenceEngine` 固化 `InferenceEngine` 的生命周期、能力门控、流式事件、指标与取消语义；IOS-12a 已能显式下载、校验、激活和管理 MLX-community 模型。当前阻塞是：商店激活后仍返回确定性 Mock 文本，不是真实大模型回答。

IOS-13 只覆盖端侧文字聊天，不引入语音、视觉或云端推理。候选后端仍是 MLX Swift、llama.cpp 和 Core ML。

约束：

1. 后端必须继续藏在 `InferenceEngine` 协议后，`AppModel` 和聊天 UI 不感知 MLX。
2. 首批商店目录已是 `mlx-community` 模型，必须直接复用已落盘目录。
3. 生成必须流式、可打断，并输出首 token、总时长、输出字符数。
4. 纯域逻辑测试仍不能要求模型权重和网络。
5. iOS 优先；不因后端引入静默云端路径。

## 决策

1. 选择 **MLX Swift LM** 作为 IOS-13 真实文字推理后端。
2. 引入依赖：
   - `https://github.com/ml-explore/mlx-swift-lm`（锁到 `3.32.x`，当前解析为 `3.32.3`；manifest 使用 Swift Tools 6.2）
   - `https://github.com/huggingface/swift-huggingface`（`0.9.0+`）
   - `https://github.com/huggingface/swift-transformers`（`1.3.0+`）
3. **平台约束**：MLX Swift LM `3.32.3` manifest 要求 iOS 17+ / macOS 14+。为保持真实后端可用，`EdgeAssistantCore` 与 App target 的 iOS deployment target 从 iOS 16 提升到 iOS 17；SwiftPM manifest 使用 Swift Tools 6.2，但本项目 Swift 源码语言模式保持 v5，避免一次性把全部域层迁入严格并发模式。
4. `EdgeAssistantCore` 内新增 `MLXInferenceEngine`，包装 `LLMModelFactory.shared.loadContainer(...)` 得到的 `ModelContainer`。
5. 已安装 MLX 商店资产在 `ModelAsset.localDirectory` 携带目录、`format` 携带格式；引擎工厂按这两个字段创建真实 MLX 引擎。无目录的内置模拟资产继续使用 Mock。
6. Prompt 转成结构化 chat 输入：系统提示 + 用户消息。IOS-13 暂不携带历史轮次，避免先实现完整上下文预算时阻塞真实后端接入。
7. 生成取消映射到 Swift 任务取消； MLX 流循环随任务取消退出并记录 `cancelled: true`。
8. 文本上限继续由温控计划通过 `InferenceRequest.maxOutputChars` 传入；MLX 侧用 token 数近似约束，UI 指标仍统计字符数。

## 备选方案

### 方案 A：MLX Swift LM（已选择）

优点：与现有 `mlx-community` 资产格式一致；Apple Silicon/iOS 集成路径官方；支持流式生成；模型加载和 tokenizer 可从本地目录读取。

缺点：引入较大原生依赖；API 演进较快；需要真机验证性能与内存。

### 方案 B：llama.cpp

优点：GGUF 生态成熟，跨平台复用性好。

缺点：现有商店目录是 MLX 资产；GGUF 转换、tokenizer/chat template 与下载文件都要改造；接入成本高于本阶段目标。

### 方案 C：Core ML

优点：系统级集成好。

缺点：开源 LLM 权重和聊天模板生态不如 MLX 直接；流式与量化工作流改造更大。

## 结果

IOS-13 打通“商店 MLX 模型 → 本地目录 → `MLXInferenceEngine` → 流式聊天”。上层仍只依赖 `InferenceEngine`，后续 llama.cpp / Core ML 可按同一协议做并行评测。

### 非目标

- 不接入语音、VLM 或视频。
- 不在仓库中提交模型权重。
- 不改变商店显式下载语义。
- 不做静默云端 fallback。
- 不在本 ADR 内实现完整多轮上下文预算；该能力继续按 `docs/design.md` 的上下文策略推进。
