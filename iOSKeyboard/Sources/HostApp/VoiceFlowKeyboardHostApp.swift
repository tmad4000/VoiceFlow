import SwiftUI

@main
struct VoiceFlowKeyboardHostApp: App {
    @StateObject private var router = HostRouter()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(router)
                .onOpenURL { url in
                    router.handle(url: url)
                }
        }
    }
}
