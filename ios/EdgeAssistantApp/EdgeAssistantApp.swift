import SwiftUI

@main
struct EdgeAssistantApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environmentObject(model)
                // 安装即内置：启动即自动校验装载自带模型，无用户操作。
                .task {
                    await model.autoProvision()
                    model.startThermalMonitoring()
                    #if DEBUG
                    model.runAutoChatIfRequested()
                    model.openStoreIfRequested()
                    model.runStoreDownloadDemoIfRequested()
                    #endif
                }
                .onChange(of: scenePhase) { phase in
                    guard phase == .active else { return }
                    model.refreshThermalState()
                }
        }
    }
}
