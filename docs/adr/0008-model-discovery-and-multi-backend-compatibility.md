# ADR 0008：联网模型发现、兼容性校验与多 MLX 后端

## 状态

已采纳（2026-11-06）

## 背景

模型商店目前使用静态仓库清单，只覆盖少量单权重 MLX 文字模型。用户希望联网发现端侧模型，并明确判断 MNN-Pocket 0.3B、MiniCPM-V 4.7 35B-A3B 与 Gemma 4 E2B 是否可下载、部署和使用。当前 MLX Swift LM 已支持文本 LLM 与部分 VLM，但仓库名或 HuggingFace 标签不能等价于本 App 可执行。

## 决策

1. **联网发现只发现候选，不直接承诺可执行。**
   - App 通过 HuggingFace Models API 搜索 `text-generation` / `image-text-to-text` 仓库。
   - 对候选仓库读取 `config.json` 的 `model_type` / `architectures` 和文件树。
   - 兼容性检查器按本机已集成后端的 registry 给出 `supported`、`requiresConversion` 或 `unsupported`。
   - 只有 `supported` 的候选展示“下载并部署”。
2. **动态下载使用 HuggingFace 文件树清单。**
   - 下载 `config.json`、tokenizer/processor 配置、generation 配置、chat template、权重 index 与全部分片权重。
   - 权重校验改为流式 SHA-256，不允许为校验把数 GB 文件读入内存。
   - 下载仍是显式用户动作；下载前检查卷剩余空间，保留镜像回退。
3. **MLX 引擎按模型形态选择 factory。**
   - `mlx` 文本模型继续走 `LLMModelFactory`。
   - `mlx-vlm` 模型走 `MLXVLM` 的 `VLMModelFactory`。
   - 本阶段 VLM 只保证纯文字对话路径；图像/视频输入仍属后续多模态设计，不作为已交付能力。
4. **请求列表的兼容性结论透明呈现。**
   - `mlx-community/gemma-4-e2b-it-4bit`：`gemma4` 架构由 MLXVLM registry 支持，作为受支持的 VLM 文字对话目标；真机加载验收仍必须执行。
   - `mlx-community/MiniCPM-V-4.7-35B-A3B-OptiQ-4bit`：`minicpmv4_7` 不在当前 `MLXVLM` registry，状态为 `unsupported`，不提供下载按钮。
   - `taobao-mnn/MNN-Pocket-0.3B`：仓库标签是 MNN，即使暴露 Qwen3 safetensors，也不能假定满足 MLX tensor/quantization 布局；状态为 `requiresConversion`，不直接部署。只有 MLX-community 明确转换版且兼容检查通过后才可下载。
5. **任意 HuggingFace 仓库禁止盲跑。**
   - 未识别架构、缺失权重 index、非 MLX 量化、专有 MNN/MNNMLC 产物都不得进入激活路径。

## 后果

- 用户可联网发现并只安装真实可用的端侧模型，避免下载数 GB 后才发现不可执行。
- Gemma 4 E2B 进入可支持列表，但仍需真机确认内存、首 token 延迟和流式打断。
- MiniCPM-V 4.7 与原生 MNN 仓库保持明确不可用状态；若后续引入对应转换器或独立 MNN backend，需要新增 ADR。

## 非目标

- 不支持任意模型盲试。
- 不在端侧做云模型推理或模型格式自动上传转换。
- 不在本 ADR 承诺图像/视频输入。
