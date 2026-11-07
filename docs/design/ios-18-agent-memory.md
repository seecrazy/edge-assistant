# IOS-18：分层记忆、生命周期与混合召回

## 目标

- 记忆区分 semantic / episodic，并有 confirmed / pending 生命周期。
- pending 候选永不自动进入 prompt。
- 用户可确认、忽略、编辑和删除单条记忆。
- 本地混合召回综合考虑词汇 overlap、时间衰减和记忆类型。
- 注入 MLX 的工作记忆有条数和字符预算。
- 全部记忆继续留在加密 SQLite 和本机。

## 非目标

- 不实现云端 embedding 或隐式联网记忆检索。
- 不实现自动主题分区和来源审计（后续阶段）。
- 不引入第三方向量数据库或明文检索列。
- 不让 pending 记忆以“可能事实”的形式悄悄影响回答。

## 数据与状态模型

```swift
enum AgentMemoryKind { case semantic, episodic }
enum AgentMemoryStatus { case confirmed, pending }

struct AgentMemoryRecord {
  let id: UUID
  var text: String
  var kind: AgentMemoryKind
  var status: AgentMemoryStatus
  var confidence: Double
  let createdAt: Date
  var lastSeenAt: Date
  let sourceExcerpt: String
}
```

- `semantic`：身份、偏好、职业、长期约束。
- `episodic`：“记住……”、约会、任务、项目节点。
- `pending`：从非显式句式推断出的候选。
- `confirmed`：用户确认或显式“记住……”的记忆。
- SQLite 仍使用 `agent_blob(kind="records")`，payload 为整包 JSON 的 AES-GCM combined ciphertext。

## 用户流程

1. 用户输入“我喜欢乌龙茶”：App 提取 semantic 候选，标记 pending，并在聊天中提示到设置里确认。
2. 用户输入“记住周五复盘”：App 提取 episodic 记忆，直接 confirmed，可立即召回。
3. Agent 设置分两区显示“待确认”和“已确认”；待确认只提供确认/忽略，不参与召回。
4. 已确认记录可编辑、保存或删除；编辑后 `lastSeenAt` 更新。
5. 发送新消息时，Store 用混合召回选择 confirmed 记忆，再按预算装箱进 prompt。

## 召回与工作记忆

- 特征：归一化词、CJK 单字和短词字符特征；全部本地计算。
- 相关性：跨记录计算特征 IDF，统计 query 覆盖。
- 时间：按 `lastSeenAt` 做 21 天半衰期衰减。
- 类型：semantic 略高于 episodic，适配稳定个性化上下文。
- 装箱：最多 5 条、默认 1200 字符；不截断单条记忆，放不下则跳过。
- 空结果：返回最近 confirmed 记忆，保证连续性。

## 边界与错误处理

- 解密失败：停止加载，不回退明文。
- 记录库不存在：从旧 `facts` blob 一次性升级；旧 confirmed 记忆保留原语义。
- 忽略/删除：物理移除记录，不做隐藏标记。
- 编辑为空或超长：拒绝，保留原文本。
- 清除全部数据：销毁 Keychain 数据密钥后清空密文，与 IOS-15 语义一致。

## 验收清单

- [x] 显式“记住”生成为 confirmed episodic 记忆。
- [x] 推断身份/偏好生成为 pending semantic 候选。
- [x] pending 不出现在 recall 与 prompt。
- [x] confirmed 可编辑、确认、忽略、删除。
- [x] 混合召回可按词汇、时间和类型排序。
- [x] 工作记忆最多 5 条且遵守字符预算。
- [x] prompt 明确显示记忆分层与用途边界。
- [x] 所有业务 payload 仍为 AES-GCM 密文。
- [x] 域层测试全绿，iOS App 构建通过。
