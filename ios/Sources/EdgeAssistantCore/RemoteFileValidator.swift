import Foundation

/// 下载后与激活前共用：拒绝 HTML/空文件/LFS pointer/截断 Safetensors 进入推理。
public enum RemoteFileValidator {
    private static let maxJSONBytes: Int64 = 64 * 1_024 * 1_024
    private static let maxSafetensorsHeaderBytes: Int64 = 32 * 1_024 * 1_024

    public static func validateFile(at url: URL, relativePath: String) throws {
        let values = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (values?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            throw ModelStoreError.invalidModelFile(relativePath, "文件为空")
        }

        switch normalizedExtension(relativePath) {
        case "json":
            try validateJSON(at: url, relativePath: relativePath, size: size)
        case "safetensors":
            try validateSafetensors(at: url, relativePath: relativePath, size: size)
        case "jinja":
            let data = try Data(contentsOf: url)
            if String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                throw ModelStoreError.invalidModelFile(relativePath, "模板文件为空")
            }
        default:
            break
        }
    }

    /// 商店模型安装目录预检：先挡住明显坏文件，再让引擎真实加载。
    public static func validateModelDirectory(at directory: URL) throws {
        let config = directory.appendingPathComponent("config.json")
        let tokenizer = directory.appendingPathComponent("tokenizer.json")
        for required in [config, tokenizer] where !FileManager.default.fileExists(atPath: required.path) {
            throw ModelStoreError.invalidModelFile(required.lastPathComponent, "必需文件缺失")
        }

        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent != "metadata.json" {
            try validateFile(at: file, relativePath: file.lastPathComponent)
        }

        let hasWeights = files.contains { $0.pathExtension.lowercased() == "safetensors" }
        guard hasWeights else {
            throw ModelStoreError.invalidModelFile("*.safetensors", "缺少模型权重")
        }
    }

    private static func validateJSON(at url: URL, relativePath: String, size: Int64) throws {
        guard size <= maxJSONBytes else {
            throw ModelStoreError.invalidModelFile(relativePath, "JSON 文件异常过大")
        }
        let data = try Data(contentsOf: url)
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ModelStoreError.invalidModelFile(relativePath, "JSON 解析失败")
        }
    }

    private static func validateSafetensors(at url: URL, relativePath: String, size: Int64) throws {
        guard size >= 8 else {
            throw ModelStoreError.invalidModelFile(relativePath, "Safetensors 文件过短")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let prefix = try handle.read(upToCount: 8), prefix.count == 8 else {
            throw ModelStoreError.invalidModelFile(relativePath, "无法读取 Safetensors header")
        }
        let headerLength = prefix.reversed().reduce(0) { ($0 << 8) | UInt64($1) }
        guard headerLength >= 2, headerLength <= UInt64(maxSafetensorsHeaderBytes),
              headerLength + 8 <= UInt64(size) else {
            throw ModelStoreError.invalidModelFile(relativePath, "Safetensors header 长度非法")
        }
        guard let headerData = try handle.read(upToCount: Int(headerLength)),
              headerData.count == Int(headerLength) else {
            throw ModelStoreError.invalidModelFile(relativePath, "Safetensors header 被截断")
        }
        do {
            let object = try JSONSerialization.jsonObject(with: headerData)
            guard let tensors = object as? [String: Any], !tensors.isEmpty else {
                throw ModelStoreError.invalidModelFile(relativePath, "Safetensors header 不是对象")
            }
            // `__metadata__` 合法存在；每个张量都必须有 offsets，避免把任意 JSON 当权重。
            // Safetensors 允许标量张量，因此 shape 可以是空数组。
            let tensorEntries = tensors.filter { $0.key != "__metadata__" }
            guard !tensorEntries.isEmpty else {
                throw ModelStoreError.invalidModelFile(relativePath, "Safetensors header 没有张量")
            }
            for (_, value) in tensorEntries {
                guard let tensor = value as? [String: Any],
                      tensor["dtype"] is String,
                      let shape = tensor["shape"] as? [Any],
                      let offsets = tensor["data_offsets"] as? [Any], offsets.count == 2 else {
                    throw ModelStoreError.invalidModelFile(relativePath, "Safetensors 张量描述非法")
                }
                let endOffset = (offsets.last as? NSNumber)?.int64Value ?? -1
                guard endOffset >= 0, headerLength + 8 + UInt64(endOffset) <= UInt64(size) else {
                    throw ModelStoreError.invalidModelFile(relativePath, "Safetensors 张量数据被截断")
                }
            }
        } catch let error as ModelStoreError {
            throw error
        } catch {
            throw ModelStoreError.invalidModelFile(relativePath, "Safetensors header 解析失败")
        }
    }

    private static func normalizedExtension(_ path: String) -> String {
        (path as NSString).pathExtension.lowercased()
    }
}
