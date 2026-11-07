# ADR 0011：按运行时能力做模型发现与下载交互

## 状态

Accepted

## 背景

真机反馈两个问题：

1. Gemma 4 E2B 显示“可用”，点击“下载并部署”没有可见反应；部分原因是设备档位不足时按钮被静默禁用，部分原因是下载前解析远端 manifest 阶段没有状态。
2. “刷新推荐端侧模型”串行访问 HuggingFace search + 每个候选 config/metadata，最坏会发出大量长超时请求，UI 长时间转圈。
3. 用户期望“支持所有端侧模型”，但 App 当前只有一个本地推理运行时：MLX Swift LM。GGUF、MNN、ONNX、原生 PyTorch/BF16 大权重都不能当作可直接执行模型。

## 目标

1. 模型兼容性按当前 MLX LLM/VLM registry 的架构能力判定，而不是少量手写示例。
2. 非 MLX 布局必须标记为“需转换”，不能直接下载。
3. 搜索候选并行探测、限制数量和超时，避免 UI 卡死。
4. “下载并部署”在解析清单、下载、激活每个阶段都有可见状态；成功后自动激活。
5. 设备档位只作为推荐/风险提示，不再静默禁用用户显式选择的 supported 模型。

## 非目标

- 不承诺运行任意 HuggingFace 模型。
- 不在本轮实现 GGUF、MNN、ONNX 转换器或第三方运行时。
- 不承诺所有模型都能塞进当前 iPhone 内存；激活阶段仍会真实加载并失败保护。
- 不承诺图像输入；VLM 仍只开放文字 chat。

## 设计

- `ModelCompatibilityChecker` 使用与 MLX Swift LM 3.32 registry 对齐的架构白名单：
  - text registry 中的文字架构映射 `mlx`
  - vision registry 中的多模态架构映射 `mlx-vlm`
  - `mlx-community`、`mlx` tag、`-mlx` 仓库名才视为 MLX 权重布局
  - MNN / GGUF / ONNX / 原始 transformers 布局标记 `requiresConversion`
  - 架构不在 runtime registry 内标记 `unsupported`
- 搜索客户端使用独立短超时 URLSession，默认最多探测 12 个候选，配置探测并行执行；用户搜索词会扩展出 `mlx-community` 与 4bit/8bit 变体，候选先按仓库去重再探测，结果优先展示 supported 且体积较小者。
- `config.json` 探测和远程候选下载必须支持 `hf-mirror.com` 回退：主源 `config.json` / tree / 权重请求失败时直接改用镜像；镜像也不可用才显示“待检查”或下载失败。
- App 下载阶段新增 `isResolvingManifest`，随后继续显示分文件进度；下载成功后自动激活。
- UI 对 unsupported/requiresConversion 显示具体原因；supported 不因 tier 静默禁用，只显示硬件风险提示。

## 边界与错误处理

- 远端单个候选探测失败不导致整次搜索失败，该候选显示 unknown。
- 主源探测失败但镜像可用时，候选不能停留在 unknown；必须按镜像读到的 `config.json` 正常分类并允许下载。
- search 结束或取消后必须复位 loading 状态。
- 激活失败保留旧引擎并显示具体文件/内存错误。
- MNN Pocket 继续不可直接下载；MiniCPM-V 4.7 因当前 registry 无 `minicpmv4_7` 继续 unsupported。
- 小内存机型看到内存负担标签与排序后的小模型优先；内存标签不替代激活前的真实内存护栏。

## 验收

- Gemma 4 E2B supported 可点击，下载/解析/激活有状态。
- 刷新推荐最多并行探测少量候选，失败后 spinner 复位并显示错误。
- 静态 Qwen/Llama/Gemma 可直接下载；MiniCPM/MNN 显示不可直接部署。
- 42+ Swift 域层测试和 iOS Simulator 构建通过。
