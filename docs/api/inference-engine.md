# Inference Engine API

## 状态

M1 参考契约，已由 `prototype/js/inference-engine.js` 实现。

iOS 已按同一语义实现：

- `MockInferenceEngine`：确定性流式输出，用于内置模拟资产、纯域测试和无网络回归。
- `MLXInferenceEngine`（ADR 0006）：包装 MLX Swift LM `3.32.3`，从已安装模型目录加载并生成真实文字流。
- `InferenceEngineFactory`：`ModelAsset.localDirectory + format` 选择真实 MLX 或内置 Mock。

## 设计目标

移动端最终会有多个推理后端：

- Android：llama.cpp / MLC-LLM / QNN 等适配层。
- iOS：Core ML / MLX 等适配层。

上层会话编排不感知平台差异，只依赖统一的生命周期、能力门控、流式输出和取消语义。

## 生命周期

```text
unloaded ──load(asset)──▶ ready
ready ────unload()────▶ unloaded
```

约束：

1. `load` 必须接收已通过完整性校验的 `ModelAsset`。
2. `ready` 状态才允许推理。
3. 资产能力不包含当前模式时，必须直接拒绝，不允许静默降级到其他模式。
4. `unload` 后必须释放推理上下文和显存/内存。

## ModelAsset

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | string | 资产唯一 ID |
| `tier` | `flagship` / `mainstream` / `entry` | 设备档位 |
| `version` | semver `x.y.z` | 资产版本 |
| `sha256` | 64 位十六进制字符串 | 完整性校验值 |
| `sizeBytes` | positive integer | 资产大小 |
| `capabilities` | `chat` / `voice` / `video` 子集 | 支持的模式 |
| `localDirectory` | URL，可选 | 商店已安装模型目录；内置模拟资产为 nil |
| `format` | string，可选 | 模型格式；iOS 工厂用 `mlx` 前缀识别 MLX 后端 |

## generateStream

```js
for await (const event of engine.generateStream({
  mode: "voice",
  prompt: transcript,
  signal: abortController.signal,
})) {
  // event.type === "token" | "done"
}
```

事件：

- `token`：可增量渲染或送入流式 TTS 的文本片段。
- `done`：推理完成，附带 `firstTokenMs`、`durationMs`、`outputChars`、`plannedFirstTokenMs`。

取消：

- 输入 `AbortSignal.aborted` 时立即抛出 `AbortError`。
- 流式过程中收到取消信号时，停止输出并记录 `cancelled: true` 指标。
- 上层必须同时停止 TTS、丢弃未播放音频并取消未完成推理。

## Model Registry

`prototype/js/model-registry.js` 提供：

- `validateModelAsset(asset)`：元数据校验。
- `verifyModelAsset(asset, bytes)`：SHA-256 完整性校验。
- `createModelRegistry(assets)`：注册与档位选择。
- `createModelAssetManager()`：
  - `install(asset, bytes)`：校验失败时不改变当前 active asset。
  - `rollback()`：回到上一次成功激活的资产。
  - `status()`：返回 active、rollback、错误和安装计数。

回滚是单步的，避免移动端保存多份 1–2GB 模型造成存储放大。更长的历史版本留在资产包或远端索引中，不在运行时常驻。

## 当前限制

浏览器原型不是真实大模型推理：

- 回复由确定性模拟策略生成。
- 占位模型字节只用于验证 hash 与回滚流程。
- 延迟指标中的 `plannedFirstTokenMs` 是目标值，不是设备实测值。

iOS MLX 后端代码已完成并可通过构建/纯域测试；真实模型输出、真机延迟和打断效果仍需显式下载权重后在设备上验收。

