import Foundation

public enum ModelCompatibility: String, Codable, Sendable {
    case supported
    case requiresConversion
    case unsupported
    case unknown
}

public struct RemoteModelCandidate: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let repositoryID: String
    public let modelType: String?
    public let architectures: [String]
    public let compatibility: ModelCompatibility
    public let compatibilityReason: String?
    public let estimatedSizeBytes: Int64
    public let tags: [String]

    public init(
        id: String,
        repositoryID: String,
        modelType: String?,
        architectures: [String],
        compatibility: ModelCompatibility,
        compatibilityReason: String?,
        estimatedSizeBytes: Int64,
        tags: [String]
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.modelType = modelType
        self.architectures = architectures
        self.compatibility = compatibility
        self.compatibilityReason = compatibilityReason
        self.estimatedSizeBytes = estimatedSizeBytes
        self.tags = tags
    }
}

public protocol RemoteModelMetadataFetching: Sendable {
    func probe(repositoryID: String) async throws -> RemoteModelCandidate
    func searchModels(query: String, limit: Int) async throws -> [RemoteModelCandidate]
}

public protocol RemoteModelManifestProviding: Sendable {
    func files(repositoryID: String, mirrorBase: String?) async throws -> [RemoteModelFile]
}

/// 只允许当前已集成的 MLX registry 执行模型；发现结果绝不因仓库名而盲目承诺可运行。
public enum ModelCompatibilityChecker {
    private static let textModelTypes: Set<String> = [
        "qwen2", "qwen3", "llama", "llama4", "gemma", "gemma2", "gemma3_text",
        "minicpm", "smollm2", "phi3", "phi3small", "phi4", "internlm2",
    ]
    private static let visionModelTypes: Set<String> = [
        "gemma3", "gemma4", "gemma4_unified", "qwen2_vl", "qwen2_5_vl",
        "qwen3_vl", "qwen3_vl_moe", "paligemma", "idefics3", "smolvlm",
        "pixtral", "mistral3", "lfm2_vl", "glm_ocr",
    ]
    private static let blockedFragments: Set<String> = [
        "minicpmv4_7", "minicpm-v-4.7", "minicpmv4.7", "35b-a3b",
    ]

    public static func check(
        repositoryID: String,
        modelType: String?,
        architectures: [String] = [],
        tags: [String] = []
    ) -> (compatibility: ModelCompatibility, reason: String?, backend: String?, format: String?) {
        let normalizedRepo = repositoryID.lowercased()
        let normalizedType = modelType?.lowercased()
        let normalizedTags = Set(tags.map { $0.lowercased() })
        let normalizedArchitectures = Set(architectures.map { $0.lowercased() })

        if normalizedRepo.contains("taobao-mnn") || normalizedRepo.contains("-mnn")
            || normalizedTags.contains("mnn") {
            return (
                .requiresConversion,
                "MNN 仓库的权重布局不能假定兼容 MLX；需要 MLX 转换版后重新检查。",
                nil, nil
            )
        }

        let hasMLXLayout = normalizedRepo.hasPrefix("mlx-community/")
            || normalizedRepo.contains("/-mlx")
            || normalizedRepo.hasSuffix("-mlx")
            || normalizedTags.contains("mlx")
            || normalizedTags.contains("mlx_llm")
            || normalizedTags.contains("mlx_vlm")

        let hasOtherRuntimeLayout = normalizedTags.contains("gguf")
            || normalizedTags.contains("onnx")
            || normalizedRepo.contains(".gguf")
            || normalizedRepo.contains("-gguf")
            || normalizedRepo.contains("-onnx")
            || normalizedArchitectures.contains("gguf")
            || normalizedArchitectures.contains("onnx")

        if hasOtherRuntimeLayout || !hasMLXLayout {
            return (
                .requiresConversion,
                hasOtherRuntimeLayout
                    ? "该仓库是 GGUF/ONNX/MNN 等运行时布局；需要 MLX 转换版后重新检查。"
                    : "未发现 MLX 权重布局标记；原始 transformers 权重需要 MLX 转换后才能加载。",
                nil, nil
            )
        }

        guard let modelType = normalizedType, !modelType.isEmpty else {
            return (.unknown, "MLX 仓库未能读取 config.json 的 model_type。", nil, nil)
        }

        if blockedFragments.contains(modelType) || blockedFragments.contains(normalizedRepo) {
            return (.unsupported, "当前 MLX Swift LM registry 不支持 \(modelType)。", nil, nil)
        }

        if visionModelTypes.contains(modelType) {
            return (.supported, "MLXVLM 支持该架构；当前仅启用纯文字对话。", "MLXVLM", "mlx-vlm")
        }
        if textModelTypes.contains(modelType) {
            return (.supported, "MLXLLM 支持该文字模型架构。", "MLXLLM", "mlx")
        }

        let architectureHit = architectures.map { $0.lowercased() }.contains {
            $0.contains("minicpmv") || $0.contains("minicpm-v")
        }
        if architectureHit {
            return (.unsupported, "当前 MLX Swift LM registry 不支持该 MiniCPM-V 架构。", nil, nil)
        }

        return (.unsupported, "架构 \(modelType) 不在本 App 当前兼容性白名单内。", nil, nil)
    }
}

/// HuggingFace Models API 发现客户端。测试注入 URLSession / URLProtocol，不在单元测试访问网络。
public struct HuggingFaceModelCatalogClient: RemoteModelMetadataFetching, RemoteModelManifestProviding {
    private let session: URLSession
    private let probeLimit: Int

    public init(session: URLSession = HuggingFaceModelCatalogClient.defaultSession(), searchProbeLimit: Int = 12) {
        self.session = session
        self.probeLimit = searchProbeLimit
    }

    /// 搜索探测是短请求；不让慢节点把模型商店 spinner 挂住。
    public static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    public func probe(repositoryID: String) async throws -> RemoteModelCandidate {
        try await probe(repositoryID: repositoryID, searchTags: [], searchSizeBytes: nil)
    }

    private func probe(
        repositoryID: String,
        searchTags: [String],
        searchSizeBytes: Int64?
    ) async throws -> RemoteModelCandidate {
        let data: Data
        do {
            data = try await configurationData(repositoryID: repositoryID)
        } catch {
            return candidate(
                repositoryID: repositoryID,
                modelType: nil,
                architectures: [],
                tags: searchTags,
                sizeBytes: searchSizeBytes
            )
        }
        guard let config = try? JSONDecoder().decode(HFModelConfiguration.self, from: data) else {
            return candidate(
                repositoryID: repositoryID,
                modelType: nil,
                architectures: [],
                tags: searchTags,
                sizeBytes: searchSizeBytes
            )
        }
        let metadata = try? await metadata(repositoryID: repositoryID)
        return candidate(
            repositoryID: repositoryID,
            modelType: config.modelType,
            architectures: config.architectures ?? [],
            tags: searchTags,
            sizeBytes: metadata?.safeTensorBytes ?? searchSizeBytes
        )
    }

    public func searchModels(query: String, limit: Int) async throws -> [RemoteModelCandidate] {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchQueries = Self.searchQueries(for: cleaned)
        let results = try await withThrowingTaskGroup(of: [HuggingFaceSearchModel].self) { group in
            for searchQuery in searchQueries {
                let text = Self.searchURL(
                    query: searchQuery,
                    filter: "text-generation",
                    limit: limit
                )
                let vision = Self.searchURL(
                    query: searchQuery,
                    filter: "image-text-to-text",
                    limit: limit
                )
                group.addTask { [self] in
                    async let textData = data(from: text)
                    async let visionData = data(from: vision)
                    let textModels = try JSONDecoder().decode(
                        [HuggingFaceSearchModel].self,
                        from: try await textData
                    )
                    let visionModels = try JSONDecoder().decode(
                        [HuggingFaceSearchModel].self,
                        from: try await visionData
                    )
                    return textModels + visionModels
                }
            }
            var models: [HuggingFaceSearchModel] = []
            for try await result in group {
                models += result
            }
            return models
        }

        let candidates = Array(((results)
            .filter { !$0.id.lowercased().hasPrefix("datasets/") }
            .deduplicated(by: \.id)
            .prefix(min(probeLimit, max(1, limit)))))

        // 并行探测限制在前 12 个候选；单个候选失败只降级为 unknown，不拖垮整次搜索。
        let probed = try await withThrowingTaskGroup(of: RemoteModelCandidate.self) { group in
            for model in candidates {
                group.addTask { [self] in
                    do {
                        return try await self.probe(
                            repositoryID: model.id,
                            searchTags: model.tags ?? [],
                            searchSizeBytes: model.safeTensorBytes
                        )
                    } catch {
                        return self.unknownCandidate(
                            repositoryID: model.id,
                            tags: model.tags ?? [],
                            sizeBytes: model.safeTensorBytes
                        )
                    }
                }
            }
            var result: [RemoteModelCandidate] = []
            for try await candidate in group {
                result.append(candidate)
            }
            return result
        }
        return probed.sorted { left, right in
            rank(left) != rank(right) ? rank(left) < rank(right) : left.id < right.id
        }
    }

    /// 主源 config 探测失败时立刻用镜像；否则不会产生额外请求。
    private func configurationData(repositoryID: String) async throws -> Data {
        let escaped = repositoryID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repositoryID
        let primary = URL(string: "https://huggingface.co/\(escaped)/resolve/main/config.json")!
        do {
            let (data, response) = try await session.data(from: primary)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw ModelStoreError.manifestUnavailable(repositoryID)
            }
            return data
        } catch {
            let mirror = URL(string: "https://hf-mirror.com/\(escaped)/resolve/main/config.json")!
            let (data, response) = try await session.data(from: mirror)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw ModelStoreError.manifestUnavailable(repositoryID)
            }
            return data
        }
    }

    /// 搜索通用词时补充 MLX-community 和量化变体；显式完整仓库搜索保持原样。
    static func searchQueries(for query: String) -> [String] {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = cleaned.lowercased()
        guard !cleaned.isEmpty else { return ["mlx-community 4bit instruct"] }

        if lowercased.hasPrefix("mlx-community/") {
            return [cleaned]
        }
        if lowercased.contains("mlx-community") {
            return [cleaned, cleaned + " 4bit"]
        }

        var queries = [cleaned]
        if lowercased.contains("4bit") || lowercased.contains("8bit") {
            queries.append("mlx-community " + cleaned)
        } else {
            queries.append("mlx-community " + cleaned + " 4bit")
            queries.append("mlx-community " + cleaned + " 8bit")
        }
        return queries
    }

    private static func searchURL(query: String, filter: String, limit: Int) -> URL {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return URL(string: "https://huggingface.co/api/models?search=\(encodedQuery)&filter=\(filter)&limit=\(limit)&full=true")!
    }

    /// 主源清单失败时直接改用镜像 API 与镜像文件 URL，避免每个文件下载阶段再等一次主源超时。
    public func files(repositoryID: String, mirrorBase: String?) async throws -> [RemoteModelFile] {
        let escaped = repositoryID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repositoryID
        var entries: [HuggingFaceTreeEntry] = []
        var fileBase = "https://huggingface.co/\(escaped)/resolve/main/"
        var usedMirror = false
        do {
            let primaryData = try await treeData(
                repositoryID: repositoryID,
                apiBase: "https://huggingface.co/api/models/",
                escaped: escaped
            )
            entries = try JSONDecoder().decode([HuggingFaceTreeEntry].self, from: primaryData)
        } catch {
            guard mirrorBase != nil else { throw error }
            usedMirror = true
        }

        if entries.isEmpty, let mirrorBase {
            let mirrorData = try await treeData(
                repositoryID: repositoryID,
                apiBase: Self.mirrorAPIBase(mirrorBase),
                escaped: escaped
            )
            entries = try JSONDecoder().decode([HuggingFaceTreeEntry].self, from: mirrorData)
            fileBase = mirrorBase
            usedMirror = true
        }

        if entries.isEmpty {
            throw ModelStoreError.manifestUnavailable(repositoryID)
        }

        let files = entries.filter { $0.type == .file }.compactMap { entry -> RemoteModelFile? in
            guard Self.isRequired(entry.path) else { return nil }
            let escapedPath = entry.path
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entry.path
            return RemoteModelFile(
                path: entry.path,
                url: URL(string: escapedPath, relativeTo: URL(string: fileBase)!)!.absoluteURL,
                sizeBytes: entry.size
            )
        }
        guard files.contains(where: { $0.path.hasSuffix(".safetensors") }) else {
            throw ModelStoreError.manifestUnavailable(repositoryID)
        }
        return files
    }

    static func mirrorAPIBase(_ mirrorBase: String) -> String {
        guard let url = URL(string: mirrorBase),
              let host = url.host else {
            return "https://hf-mirror.com/api/models/"
        }
        let scheme = url.scheme ?? "https"
        return "\(scheme)://\(host)/api/models/"
    }

    private func treeData(
        repositoryID: String,
        apiBase: String,
        escaped: String
    ) async throws -> Data {
        let url = URL(string: "\(apiBase)\(escaped)/tree/main?recursive=true")!
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModelStoreError.manifestUnavailable(repositoryID)
        }
        return data
    }

    private func data(from url: URL) async throws -> Data {
        let (data, _) = try await session.data(from: url)
        return data
    }

    private func metadata(repositoryID: String) async throws -> HuggingFaceSearchModel? {
        let escaped = repositoryID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repositoryID
        let url = URL(string: "https://huggingface.co/api/models/\(escaped)")!
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode(HuggingFaceSearchModel.self, from: data)
    }

    private func candidate(
        repositoryID: String,
        modelType: String?,
        architectures: [String],
        tags: [String],
        sizeBytes: Int64?
    ) -> RemoteModelCandidate {
        let check = ModelCompatibilityChecker.check(
            repositoryID: repositoryID,
            modelType: modelType,
            architectures: architectures,
            tags: tags
        )
        return RemoteModelCandidate(
            id: repositoryID,
            repositoryID: repositoryID,
            modelType: modelType,
            architectures: architectures,
            compatibility: check.compatibility,
            compatibilityReason: check.reason,
            estimatedSizeBytes: max(sizeBytes ?? 0, check.compatibility == .supported ? 500_000_000 : 1),
            tags: tags
        )
    }

    private func unknownCandidate(
        repositoryID: String,
        tags: [String] = [],
        sizeBytes: Int64? = nil
    ) -> RemoteModelCandidate {
        candidate(
            repositoryID: repositoryID,
            modelType: nil,
            architectures: [],
            tags: tags,
            sizeBytes: sizeBytes
        )
    }

    private func rank(_ candidate: RemoteModelCandidate) -> Int {
        switch candidate.compatibility {
        case .supported: return 0
        case .requiresConversion: return 1
        case .unknown: return 2
        case .unsupported: return 3
        }
    }

    public static func isRequired(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        if path != (path as NSString).lastPathComponent { return name.hasSuffix(".safetensors") }
        let exact: Set<String> = [
            "config.json", "generation_config.json", "model.safetensors.index.json",
            "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json",
            "chat_template.json", "chat_template.jinja", "preprocessor_config.json",
            "processor_config.json", "video_preprocessor_config.json",
        ]
        return exact.contains(name) || name.hasSuffix(".safetensors")
    }
}

private struct HFModelConfiguration: Decodable {
    let modelType: String?
    let architectures: [String]?

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case architectures
    }
}

struct HuggingFaceSearchModel: Decodable, Sendable {
    let id: String
    let tags: [String]?
    let safetensors: SafeTensorSize?

    struct SafeTensorSize: Decodable, Sendable {
        let total: Int64?
    }

    var safeTensorBytes: Int64? { safetensors?.total }
}

struct HuggingFaceTreeEntry: Decodable, Sendable {
    enum EntryType: String, Decodable, Sendable {
        case file, directory
    }

    let type: EntryType
    let path: String
    let size: Int64?
}

private extension Sequence {
    func deduplicated(by keyPath: KeyPath<Element, String>) -> [Element] {
        var seen = Set<String>()
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}
