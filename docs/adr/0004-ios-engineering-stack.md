# ADR 0004: iOS 工程结构与推理后端选型

## 状态

已接受

## 背景

iOS 端进入正式开发。需要决定：工程结构（App target 与域层代码如何组织）、推理后端抽象（MLX / llama.cpp / Core ML 如何共存）、并发模型与测试方式。

约束：

1. 核心域逻辑（机型分级、状态机、资产校验、自动装载）必须平台无关、可单元测试。
2. 推理后端仍在 M1 评估期，不能让上层依赖某个具体后端。
3. CI 与本地开发需要无真机、无模型文件也能跑全部测试。

## 决策

1. **Swift Package 承载域层**：新建 `ios/EdgeAssistantCore` Swift Package，收纳全部平台无关逻辑；App target（后续 M2 建立）只做 UI 与系统服务粘合。
2. **协议先行**：推理后端统一收敛到 `InferenceEngine` 协议；M1 提供 `MockInferenceEngine` 确定性实现固化语义（流式、取消、指标），真实后端（MLX / llama.cpp 适配层）按同一协议接入。
3. **Swift Concurrency**：域层使用 actor（资产安装器）与 `AsyncThrowingStream`（流式推理）；取消语义对齐设计的 AbortSignal（`Task` 取消）。
4. **加密与资产**：SHA-256 校验用 CryptoKit；密钥与数据库设计见 `docs/design-ios.md`，实现排期见进度文档。

## 备选方案

### 方案 A：直接建 App 工程，逻辑写在 App target

缺点：逻辑与 UI 耦合，无法在 macOS CLI 上快速回归；后端切换成本高。

### 方案 B：域层 Swift Package + 后端协议抽象（已选择）

优点：核心逻辑与后端解耦，`swift test` 秒级回归；多后端可并存评测。

缺点：需要维护 Package 与 App 的边界纪律。

### 方案 C：等待选定真实后端后再动工

缺点：阻塞 M1；后端评估本身也需要统一协议才能公平对比。

## 结果

选择方案 B。M1 先用 Mock 后端把生命周期、取消、资产装载语义用测试钉死；真实后端按协议接入后，上层编排零改动。
