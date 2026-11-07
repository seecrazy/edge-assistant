# IOS-15：Agent 安全持久化设计

## 目标

- 会话与长期事实重启后可恢复。
- SQLite 文件、iCloud/设备备份中不出现消息或事实明文。
- 用户可显式删除 Tavily API Key。
- “清除记忆与会话”后原数据不可恢复。

## 非目标

- 不实现云端同步。
- 不引入 SQLCipher 或云 KMS。
- 不做向量索引、分层记忆和细粒度记忆生命周期（属 IOS-18）。
- 不记录或保存 Tavily Key 的明文日志/UI 回显。

## 用户流程

1. 首次持久化时，`KeychainMemoryKeyProvider` 创建 256-bit Agent 数据密钥。
2. `AgentMemoryStore` 将 transcript/facts JSON 序列化后 AES-GCM 加密，再写入 `agent_blob`。
3. 读取时按 kind 取出密文，认证解密失败则向 UI 报错并停止加载，不回退明文。
4. 旧 `agent-memory.json` / `conversation.json` 在迁移成功后删除。
5. 用户在 Agent 设置中可保存、覆盖或删除 API Key；删除后联网检索关闭。
6. 用户清除记忆与会话时，App 先删除数据密钥，再清空数据库行和旧 JSON 文件。

## 数据与状态模型

```sql
CREATE TABLE IF NOT EXISTS agent_blob(
  kind TEXT PRIMARY KEY,
  payload BLOB NOT NULL,
  updated_at INTEGER NOT NULL
)
```

- `kind = "transcript"`：最近 200 条 `AgentChatTurn` 的整体 AES-GCM 密文。
- `kind = "facts"`：最近 200 条 `MemoryFact` 的整体 AES-GCM 密文。
- Keychain Agent master key：`com.startthree.edgeassistant / agent-store-master-key`。
- Keychain Tavily key：`com.startthree.edgeassistant / tavily-search-api-key`。

## 关键交互与错误处理

- 密钥创建失败：不创建明文存储，UI 展示“本地加密数据库不可用”。
- AES-GCM 解密失败：映射为 `corruptedPayload(kind)`，停止加载对应数据。
- API Key 保存失败：保留当前开关状态，UI 展示 Keychain 错误。
- API Key 删除失败：不关闭开关，避免用户误以为检索仍可用但实际无 Key。
- 清除数据失败：UI 展示具体错误；密钥已销毁时旧密文仍不可恢复。

## 验收清单

- [x] SQLite 原始字节不包含会话/事实明文。
- [x] 旧 JSON 迁移后删除。
- [x] 错误密钥/篡改密文导致解密失败，不返回业务数据。
- [x] Agent 设置可保存、更新和删除 API Key。
- [x] 清除记忆与会话销毁数据密钥并清空密文。
- [x] 域层测试全绿。
