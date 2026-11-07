# ADR 0010：模型安装与激活预检，以及多模态状态边界

## 状态

Accepted（实现进行中）

## 背景

真机反馈：`Qwen2.5 0.5B Instruct` 可用，其他已“激活”模型首次聊天抛出 `JSON parsing failed for ...`。该错误来自 swift-transformers / MLX 加载 tokenizer、config 或 safetensors header 的阶段。当前下载链路主要校验 HTTP/大小/SHA，但多数静态目录没有 size/hash；激活阶段也只做文件存在性检查，导致坏文件或实际不可加载模型能进入“已激活”状态，到第一次聊天才失败。

同时需要固化以下产品边界：文件、图片、语音不是“已实现但隐藏”，而是分别处于不同阶段。

## 目标

1. 下载时对 JSON、Safetensors、Jinja 做结构化校验；主源坏时允许镜像重试。
2. 激活时做本地模型目录预检，阻止明显损坏/截断的模型进入聊天。
3. 激活后真实 MLX/VLM 后端立即加载 tokenizer、config 与权重容器，把加载错误暴露在激活阶段，而不是首次聊天。
4. 失败信息包含具体文件/原因，并提示删除后重新下载。
5. 文档明确文件、图片、语音/通话是尚未实现；其中语音领域状态机已有设计，但完整语音管线未实现。

## 非目标

- 不承诺任意 HuggingFace 仓库可直接运行；继续使用兼容性白名单。
- 不在无真机验证时宣称 Gemma 4 E2B 或其他模型已验收。
- 不实现图像输入、文件附件、ASR/TTS 或语音通话。
- 不把模型下载扩展到非 MLX/MNN 原生运行时。

## 关键设计

- 新增核心 `RemoteFileValidator`：
  - `.json` 非空且可被 JSON 解析。
  - `.safetensors` 前 8 字节是 little-endian header 长度，header 在文件范围内且可解析；拒绝 HTML、LFS pointer、空文件与截断权重。
  - `.jinja` 非空文本。
- 下载流程：下载 → 结构校验 → 大小校验 → SHA-256；结构/大小/摘要失败时按既有 mirror 规则回退。
- `activate(id)` 预检已安装目录：必需 `config.json`、`tokenizer.json` 和至少一个 safetensors，同时校验清单内 JSON/Jinja/Safetensors。
- `InferenceEngine` 增加 `prepare()`：Mock 立即就绪，MLX/VLM 加载真实 `ModelContainer`；App 激活时调用，确保“已激活”代表“可推理”。
- UI 继续从 `LocalizedError` 展示可读原因。

## 数据与状态模型

- 安装元数据结构不变。
- 模型状态只有安装后、激活后才可被用户选择聊天；激活失败时旧引擎保持不变。
- 旧版本安装的坏模型不会被自动删除，会在激活预检时失败并由用户手动删除/重下。

## 验收

- 空配置 / HTML 假配置 / 截断 safetensors 下载失败并清理目录。
- 主源结构损坏时镜像有效则成功；镜像也损坏则失败。
- 已安装坏模型激活失败，错误包含文件名与建议。
- 现有 36 个 Swift 域层测试继续通过。
- iOS Simulator 构建通过；真实多模型输出仍需真机验收。
