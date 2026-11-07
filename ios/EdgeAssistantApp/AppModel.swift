import Foundation
import EdgeAssistantCore

struct ChatMessage: Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant, system, source }

    let id = UUID()
    let role: Role
    var text: String
}

/// 聊天会话的 @MainActor 状态：自动装载 + 流式推理 + 打断。
@MainActor
final class AppModel: ObservableObject {
    enum ProvisionState: Equatable {
        case provisioning
        case ready
        case failed(String)
    }

    enum GenerationStage: Equatable {
        case preparing
        case generating
    }

    @Published private(set) var provisionState: ProvisionState = .provisioning
    @Published private(set) var activeAssetID: String?
    @Published var inputText = ""
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isStreaming = false
    @Published private(set) var generationStage: GenerationStage?
    @Published var showStore = false
    @Published var showSearchSettings = false
    @Published private(set) var thermalLevel: ThermalLevel = .normal
    @Published private(set) var thermalPlan = ThermalMapper.degradePlan(for: .normal)

    // MARK: 模型商店（ADR 0005）
    @Published private(set) var storeCatalog: [OpenSourceModel] = []
    @Published private(set) var installedModels: [InstalledModel] = []
    @Published private(set) var installHealth: [String: InstallHealth] = [:]
    @Published private(set) var residualInstallIDs: [String] = []
    @Published private(set) var bundledAsset: ModelAsset?
    @Published private(set) var downloadProgress: [String: Double] = [:]
    @Published private(set) var isResolvingManifest: [String: Bool] = [:]
    @Published private(set) var downloadErrors: [String: String] = [:]
    @Published private(set) var storeError: String?
    @Published private(set) var isRefreshingCatalog = false
    @Published private(set) var activatingModelID: String?
    @Published private(set) var activationErrors: [String: String] = [:]
    @Published private(set) var memoryRecords: [AgentMemoryRecord] = []
    @Published private(set) var hasSearchAPIKey = false
    @Published var webSearchEnabled = false
    @Published private(set) var agentStatus: String = "本地记忆：默认开启 · 联网检索：默认关闭"

    private let profile: DeviceProfile
    private var engine: any InferenceEngine
    private let storeManager: ModelStoreManager
    private let processInfo: ProcessInfo
    private var thermalController: ThermalHysteresisController
    private var streamTask: Task<Void, Never>?
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var thermalTask: Task<Void, Never>?
    private let memoryStore: AgentMemoryStore
    private let searchService: any WebSearchServicing
    private let keychain: KeychainStore
    private let catalogClient = HuggingFaceModelCatalogClient()

    init(
        engine: any InferenceEngine = MockInferenceEngine(),
        processInfo: ProcessInfo = .processInfo
    ) {
        self.engine = engine
        self.processInfo = processInfo
        self.thermalController = ThermalHysteresisController()
        // iOS 17+ 支持的机型均含 Neural Engine；内存由系统读取。
        let ramGB = Int(ProcessInfo.processInfo.physicalMemory >> 30)
        self.profile = try! DeviceProfile(ramGB: max(ramGB, 1), hasNPU: true)
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let modelsDir = supportDir.appendingPathComponent("EdgeAssistant/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        self.storeManager = ModelStoreManager(baseDirectory: modelsDir)
        let agentDir = supportDir.appendingPathComponent("EdgeAssistant/agent", isDirectory: true)
        self.memoryStore = AgentMemoryStore(directory: agentDir)
        self.searchService = TavilyWebSearchClient()
        self.keychain = KeychainStore()
        hasSearchAPIKey = keychain.read() != nil
        Task { await loadAgentState() }
    }

    func loadAgentState() async {
        do {
            let turns = try await memoryStore.transcript()
            if !turns.isEmpty {
                messages = turns.map { turn in
                    ChatMessage(
                        role: ChatMessage.Role(rawValue: turn.role.rawValue) ?? .system,
                        text: turn.text
                    )
                }
            }
            memoryRecords = try await memoryStore.records()
            agentStatus = memoryStatus
        } catch {
            agentStatus = "本地加密数据读取失败"
            appendMessage(.system, "读取本地加密记忆失败：\(error.localizedDescription)。不会回退到明文存储。")
        }
    }

    var isModelReady: Bool {
        if case .ready = provisionState { return true }
        return false
    }

    var profileTier: ModelTier {
        profile.tier
    }

    var isInferencePaused: Bool {
        thermalPlan.pauseInference
    }

    /// 启动序列：自带资产 → SHA-256 校验 → 激活 → 装载推理引擎。
    func autoProvision() async {
        provisionState = .provisioning
        do {
            let catalog = try BundledAssetCatalog()
            let installer = AutoInstaller(catalog: catalog, manager: ModelAssetManager())
            let result = await installer.installForTier(profile.tier)

            if result.isOK, let asset = result.asset {
                try engine.load(asset)
                bundledAsset = asset
                activeAssetID = asset.id
                provisionState = .ready
                appendMessage(.system, "内置模型已就绪（\(asset.id)，\(profile.tier.label) 档）。聊天直接调用本地模型，全程无网络。")
            } else {
                provisionState = .failed(result.reason ?? "未知原因")
                appendMessage(.system, "内置模型自动装载失败：\(result.reason ?? "未知原因")。")
            }
        } catch {
            provisionState = .failed(error.localizedDescription)
            appendMessage(.system, "内置模型自动装载异常：\(error.localizedDescription)。")
        }
    }

    func retryProvision() {
        Task { await autoProvision() }
    }

    // MARK: - 热状态（IOS-16）

    /// 启动时读取当前热状态，再监听系统热通知。
    func startThermalMonitoring() {
        refreshThermalState()
        guard thermalTask == nil else { return }

        let processInfo = self.processInfo
        thermalTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: ProcessInfo.thermalStateDidChangeNotification,
                object: processInfo
            )
            for await _ in notifications {
                self?.refreshThermalState()
            }
        }
    }

    /// App 回前台时补偿后台期间错过的热状态迁移。
    func refreshThermalState() {
        let previous = thermalLevel
        thermalLevel = thermalController.update(processInfo.thermalState)
        thermalPlan = thermalController.plan

        if thermalPlan.pauseInference, isStreaming {
            interrupt()
        }

        guard previous != thermalLevel else { return }
        if thermalPlan.pauseInference {
            appendMessage(.system, "设备过热：推理已暂停，恢复输入后仍可编辑文本。冷却后会逐级恢复。")
        } else if thermalLevel == .hot {
            appendMessage(.system, "设备较热：已禁用视觉并进一步缩短回复。")
        } else if thermalLevel == .warm {
            appendMessage(.system, "设备略热：已缩短回复长度。")
        } else {
            appendMessage(.system, "设备温度已降低：当前热档位恢复为正常。")
        }
    }

    /// DEBUG 端到端验证钩子：`--auto-chat` 启动参数触发一次自动对话。
    #if DEBUG
    func runAutoChatIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--auto-chat") else { return }
        inputText = "你好，请介绍一下你自己"
        send()
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--auto-interrupt-ms"),
              index + 1 < args.count,
              let milliseconds = Double(args[index + 1]),
              milliseconds > 0 else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(milliseconds * 1_000_000))
            self?.interrupt()
        }
    }

    func openStoreIfRequested() {
        if ProcessInfo.processInfo.arguments.contains("--open-store") {
            showStore = true
        }
    }

    /// 端到端验证：`--download-model <id>` 自动下载并激活商店模型。
    func runStoreDownloadDemoIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--download-model"), index + 1 < args.count else { return }
        let id = args[index + 1]
        Task {
            await refreshStore()
            downloadModel(id)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if installedModels.contains(where: { $0.id == id }) {
                    activateStoreModel(id)
                    showStore = true
                    break
                }
                if downloadTasks[id] == nil, downloadProgress[id] == nil { break }
            }
        }
    }
    #endif

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isModelReady, !isStreaming, !isInferencePaused else { return }
        inputText = ""
        let history = messages.map { message in
            AgentChatTurn(role: AgentChatTurn.Role(rawValue: message.role.rawValue) ?? .system, text: message.text)
        }
        appendMessage(.user, text)
        persistConversation()

        let assistant = appendMessage(.assistant, "")
        isStreaming = true
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                await self.learnMemory(from: text)
                var searchResults: [WebSearchResult] = []
                var searchQuery: String? = nil
                if self.webSearchEnabled {
                    let query = Self.webSearchQuery(from: text)
                    if let apiKey = self.keychain.read() {
                        self.appendMessage(.system, "已授权联网检索：\(query)")
                        do {
                            searchResults = try await self.searchService.search(
                                query: query, apiKey: apiKey, limit: 5
                            )
                            if searchResults.isEmpty {
                                self.appendMessage(.system, "联网检索完成，但没有返回结果；已降级为本地回答。")
                            } else {
                                for result in searchResults {
                                    self.appendMessage(.source, "\(result.title)\n\(result.url)")
                                }
                            }
                            searchQuery = query
                        } catch {
                            self.appendMessage(.system, "联网检索失败，已降级为本地回答：\(error.localizedDescription)")
                        }
                    } else {
                        self.appendMessage(.system, "联网检索已开启但缺少 API Key；已降级为本地回答。")
                    }
                }

                let memories = (try? await self.memoryStore.recall(query: text)) ?? []
                let prompt = AgentContextBuilder.buildPrompt(
                    userText: text,
                    history: history,
                    memories: memories,
                    searchResults: searchResults,
                    searchQuery: searchQuery
                )
                let plannedOutputChars = OutputLengthPlanner.targetChars(
                    userText: text,
                    thermalLimit: self.thermalPlan.chatReplyCharLimit,
                    mode: .chat
                )
                var deliveredOutputChars = 0
                let request = InferenceRequest(
                    mode: .chat,
                    prompt: prompt,
                    maxOutputChars: plannedOutputChars
                )
                self.generationStage = .preparing
                for try await event in self.engine.generateStream(request) {
                    switch event {
                    case let .token(token, _, _):
                        if self.generationStage == .preparing {
                            self.generationStage = .generating
                        }
                        deliveredOutputChars += token.count
                        self.appendText(to: assistant, token)
                    case let .done(metrics):
                        let memoryCount = (try? await self.memoryStore.facts())?.count ?? 0
                        self.appendMessage(
                            .system,
                            String(
                                format: "生成完成 · 首 token %dms · 总时长 %dms · 输出 %d 字 · 记忆 %d 条 · 检索 %d 条",
                                metrics.firstTokenMs ?? 0,
                                metrics.durationMs,
                                metrics.outputChars,
                                memoryCount,
                                searchResults.count
                            )
                        )
                    }
                }
                self.generationStage = nil
                if deliveredOutputChars == 0 {
                    self.appendMessage(.system, "模型没有返回内容。原始输入已保留，可直接重试或换更轻量模型。")
                } else if deliveredOutputChars >= plannedOutputChars {
                    self.appendMessage(.system, "已达本次端侧安全上限；原始输入与已生成内容已保留。")
                }
                self.persistConversation()
            } catch is CancellationError {
                self.generationStage = nil
                self.appendText(to: assistant, "（已打断）")
            } catch {
                self.generationStage = nil
                self.inputText = text
                self.appendMessage(.system, "推理失败：\(error.localizedDescription)")
            }
            self.isStreaming = false
        }
    }

    /// 打断：取消未完成推理（引擎记录 cancelled 指标），与设计 §5.1 一致。
    func interrupt() {
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: - 模型商店

    func refreshStore() async {
        storeCatalog = OpenSourceModelCatalog.defaultCatalog()
        installedModels = await storeManager.listInstalled()
        var healths: [String: InstallHealth] = [:]
        for installed in installedModels {
            healths[installed.id] = await storeManager.installHealth(installed.id)
        }
        installHealth = healths
        residualInstallIDs = await storeManager.residualInstallIDs()
    }

    func searchOnlineModels(_ query: String) async {
        storeError = nil
        storeCatalog = OpenSourceModelCatalog.defaultCatalog()
        isRefreshingCatalog = true
        do {
            let candidates = try await catalogClient.searchModels(query: query, limit: 12)
            let models = candidates.map(candidateModel)
            let existingSources = Set(storeCatalog.map(\.source))
            storeCatalog += models.filter { !existingSources.contains($0.source) }
            storeCatalog = storeCatalog.sorted { left, right in
                let leftSupported = left.compatibility == .supported
                let rightSupported = right.compatibility == .supported
                if leftSupported != rightSupported { return leftSupported }
                if left.sizeBytes != right.sizeBytes { return left.sizeBytes < right.sizeBytes }
                return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
            }
            if storeCatalog.count == OpenSourceModelCatalog.defaultCatalog().count {
                storeError = "没有匹配的模型；可尝试 qwen、qwen3、gemma、smollm 或 qwen 4bit。"
            }
        } catch {
            storeError = "联网模型查询失败：\(error.localizedDescription)。仍可使用内置目录。"
        }
        isRefreshingCatalog = false
    }

    func downloadModel(_ id: String) {
        guard downloadTasks[id] == nil, let model = storeCatalog.first(where: { $0.id == id }) else { return }
        guard activatingModelID == nil else {
            storeError = "当前正在激活另一个模型，请等待激活完成后再下载。"
            downloadErrors[id] = "当前正在激活另一个模型，请等待激活完成后再下载。"
            return
        }
        downloadErrors[id] = nil
        downloadProgress[id] = 0
        isResolvingManifest[id] = true
        downloadTasks[id] = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let downloadModel = try await self.modelWithResolvedManifest(model)
                self.isResolvingManifest[id] = false
                let fileCount = max(downloadModel.files.count, 1)
                _ = try await self.storeManager.download(downloadModel) { [weak self] fileIndex, fileFraction in
                    let overall = (Double(fileIndex) + fileFraction) / Double(fileCount)
                    Task { @MainActor [weak self] in
                        self?.downloadProgress[id] = overall
                    }
                }
                self.installedModels = await self.storeManager.listInstalled()
                for installed in self.installedModels {
                    self.installHealth[installed.id] = await self.storeManager.installHealth(installed.id)
                }
                self.residualInstallIDs = await self.storeManager.residualInstallIDs()
                self.activateStoreModel(id)
            } catch is CancellationError {
                // 用户取消：保留已下载文件（幂等复用）
            } catch {
                let stage = self.isResolvingManifest[id] == true ? "解析模型清单" : "下载"
                self.downloadErrors[id] = "\(stage)失败：\(error.localizedDescription)"
            }
            self.downloadTasks[id] = nil
            self.downloadProgress[id] = nil
            self.isResolvingManifest[id] = nil
        }
    }

    func cancelDownload(_ id: String) {
        downloadTasks[id]?.cancel()
    }

    /// 激活商店模型：构建 ModelAsset → 工厂选择后端 → 装载并切换引擎。
    func activateStoreModel(_ id: String) {
        guard activatingModelID == nil else { return }
        activatingModelID = id
        activationErrors[id] = nil
        Task {
            do {
                // 避免旧模型仍在解码时重叠占用内存/GPU。
                interrupt()

                let asset = try await storeManager.activate(id)
                let memoryDecision = ModelMemoryGate.evaluate(
                    modelBytes: Int64(asset.sizeBytes),
                    availableBytes: ModelMemoryGate.currentAvailableBytes()
                )
                guard memoryDecision.canLoad else {
                    let formatter = ByteCountFormatter()
                    formatter.countStyle = .memory
                    activationErrors[id] = "内存不足，已阻止激活：预计需要 \(formatter.string(fromByteCount: memoryDecision.requiredBytes))，当前可用 \(formatter.string(fromByteCount: memoryDecision.availableBytes))。请先激活更小的模型。"
                    activatingModelID = nil
                    return
                }
                #if targetEnvironment(simulator)
                // MLX 的 Metal Device 初始化在 iOS 模拟器可能直接 abort；下载可入库，推理留给真机。
                storeError = "iOS 模拟器不支持 MLX Metal 推理；请在 iPhone 真机激活该模型。"
                activatingModelID = nil
                return
                #else
                let nextEngine = InferenceEngineFactory.make(for: asset)
                try nextEngine.load(asset)
                // 真实加载 tokenizer/config/权重；失败留在旧引擎，错误显示具体文件。
                try await nextEngine.prepare()

                let oldEngine = engine
                engine = nextEngine
                oldEngine.unload()

                activeAssetID = asset.id
                appendMessage(.system, "已切换到模型 \(asset.id)（MLX 本地推理）。")
                #endif
            } catch {
                activationErrors[id] = "激活失败：\(error.localizedDescription)"
            }
            activatingModelID = nil
        }
    }

    func deleteStoreModel(_ id: String) {
        Task {
            do {
                try await storeManager.delete(id, activeModelID: activeAssetID)
                installedModels = await storeManager.listInstalled()
                residualInstallIDs = await storeManager.residualInstallIDs()
            } catch ModelStoreError.modelIsActive {
                storeError = "该模型正在使用中，请先切换到其他模型再删除。"
            } catch {
                storeError = "删除失败：\(error.localizedDescription)"
            }
        }
    }

    func cleanupResidualModel(_ id: String) {
        Task {
            do {
                try await storeManager.cleanupResidualInstall(id)
                residualInstallIDs = await storeManager.residualInstallIDs()
            } catch {
                storeError = "清理残留失败：\(error.localizedDescription)"
            }
        }
    }

    /// 商店模型切换后仍可显式回到内置 Mock 模型，形成完整多模型切换闭环。
    func activateBundledModel() {
        guard let asset = bundledAsset else { return }
        Task {
            interrupt()
            do {
                let nextEngine = MockInferenceEngine()
                try nextEngine.load(asset)
                let oldEngine = engine
                engine = nextEngine
                oldEngine.unload()
                activeAssetID = asset.id
                appendMessage(.system, "已切换到内置模型 \(asset.id)（Mock 本地推理）。")
            } catch {
                storeError = "内置模型切换失败：\(error.localizedDescription)"
            }
        }
    }

    func isDownloading(_ id: String) -> Bool {
        downloadTasks[id] != nil
    }

    // MARK: - Agent 记忆与显式联网检索

    func saveSearchSettings(enabled: Bool, apiKey: String?) {
        webSearchEnabled = enabled
        if let apiKey, !apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            do {
                try keychain.save(apiKey.trimmingCharacters(in: .whitespaces))
                hasSearchAPIKey = true
            } catch {
                agentStatus = "搜索 API Key 保存失败：\(error.localizedDescription)"
            }
        }
        agentStatus = memoryStatus
    }

    func deleteSearchAPIKey() {
        do {
            try keychain.delete()
            hasSearchAPIKey = false
            webSearchEnabled = false
            agentStatus = "已删除检索 API Key · 联网检索已关闭"
        } catch {
            agentStatus = "搜索 API Key 删除失败：\(error.localizedDescription)"
        }
    }

    func clearAgentMemory() {
        Task {
            do {
                try await memoryStore.clearAll()
                messages.removeAll()
                memoryRecords = []
                appendMessage(.system, "长期记忆与本地会话已清除。")
            } catch {
                appendMessage(.system, "清除本地加密数据失败：\(error.localizedDescription)")
            }
        }
    }

    private func learnMemory(from text: String) async {
        do {
            let added = try await memoryStore.learnCandidates(from: text)
            memoryRecords = try await memoryStore.records()
            if !added.isEmpty {
                let confirmed = added.filter { $0.status == .confirmed }
                let pending = added.filter { $0.status == .pending }
                if !confirmed.isEmpty {
                    appendMessage(.system, "已存入长期记忆：\(confirmed.map(\.text).joined(separator: "；"))")
                }
                if !pending.isEmpty {
                    appendMessage(.system, "新增待确认记忆：\(pending.map(\.text).joined(separator: "；"))。请在“联网与记忆”中确认或忽略。")
                }
            }
        } catch {
            appendMessage(.system, "本地记忆保存失败：\(error.localizedDescription)")
        }
        agentStatus = memoryStatus
    }

    func confirmMemory(_ id: UUID) {
        Task { await changeMemory { try await $0.confirm(id) } }
    }

    func dismissMemory(_ id: UUID) {
        Task { await changeMemory { try await $0.dismiss(id) } }
    }

    func deleteMemory(_ id: UUID) {
        Task { await changeMemory { try await $0.delete(id) } }
    }

    func updateMemory(_ id: UUID, text: String) {
        Task { await changeMemory { try await $0.update(id, text: text) } }
    }

    private func changeMemory(_ operation: @Sendable (AgentMemoryStore) async throws -> Void) async {
        do {
            try await operation(memoryStore)
            memoryRecords = try await memoryStore.records()
        } catch {
            appendMessage(.system, "更新本地记忆失败：\(error.localizedDescription)")
        }
        agentStatus = memoryStatus
    }

    private var memoryStatus: String {
        let confirmed = memoryRecords.filter { $0.status == .confirmed }.count
        let pending = memoryRecords.count - confirmed
        return "本地记忆：\(confirmed) 条已确认 / \(pending) 条待确认 · 联网检索：\(webSearchEnabled ? "开启" : "关闭")"
    }

    private func persistConversation() {
        let turns = messages.map { message in
            AgentChatTurn(
                role: AgentChatTurn.Role(rawValue: message.role.rawValue) ?? .system,
                text: message.text
            )
        }
        Task { try? await memoryStore.saveTranscript(turns) }
    }

    private static func webSearchQuery(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(160))
    }

    private func modelWithResolvedManifest(_ model: OpenSourceModel) async throws -> OpenSourceModel {
        guard model.requiresOnlineManifest == true || model.files.isEmpty else { return model }
        let files = try await catalogClient.files(repositoryID: model.source, mirrorBase: model.mirrorBase)
        let manifestBytes = files.reduce(Int64(0)) { $0 + ($1.sizeBytes ?? 0) }
        return OpenSourceModel(
            id: model.id,
            displayName: model.displayName,
            source: model.source,
            format: model.format,
            parameters: model.parameters,
            sizeBytes: max(model.sizeBytes, manifestBytes),
            license: model.license,
            minTier: model.minTier,
            capabilities: model.capabilities,
            files: files,
            mirrorBase: model.mirrorBase,
            modelType: model.modelType,
            compatibility: model.compatibility,
            compatibilityReason: model.compatibilityReason,
            requiresOnlineManifest: false
        )
    }

    private func candidateModel(_ candidate: RemoteModelCandidate) -> OpenSourceModel {
        let check = ModelCompatibilityChecker.check(
            repositoryID: candidate.repositoryID,
            modelType: candidate.modelType,
            architectures: candidate.architectures,
            tags: candidate.tags
        )
        let name = candidate.repositoryID.split(separator: "/").last.map(String.init) ?? candidate.repositoryID
        return OpenSourceModel(
            id: "remote-\(candidate.repositoryID.replacingOccurrences(of: "/", with: "__"))",
            displayName: name,
            source: candidate.repositoryID,
            format: check.format ?? "unknown",
            parameters: candidate.modelType ?? "未知",
            sizeBytes: max(candidate.estimatedSizeBytes, 500_000_000),
            license: "见仓库",
            minTier: candidate.estimatedSizeBytes > 4_000_000_000 ? .flagship : .entry,
            capabilities: check.compatibility == .supported ? [.chat] : [],
            files: [],
            mirrorBase: "https://hf-mirror.com/\(candidate.repositoryID)/resolve/main/",
            modelType: candidate.modelType,
            compatibility: check.compatibility,
            compatibilityReason: check.reason,
            requiresOnlineManifest: check.compatibility == .supported
        )
    }

    @discardableResult
    private func appendMessage(_ role: ChatMessage.Role, _ text: String) -> ChatMessage.ID {
        let message = ChatMessage(role: role, text: text)
        messages.append(message)
        return message.id
    }

    private func appendText(to id: ChatMessage.ID, _ text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += text
    }
}
