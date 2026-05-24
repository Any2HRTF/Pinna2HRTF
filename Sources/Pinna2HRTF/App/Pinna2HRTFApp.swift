import SwiftUI

@main
struct Pinna2HRTFApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1320, minHeight: 840)
        }
        .windowStyle(.titleBar)
        .commands {
            PipelineCommands()
        }
    }
}
