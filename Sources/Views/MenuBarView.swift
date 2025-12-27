import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VoiceFlow")
                .font(.headline)

            HStack(spacing: 6) {
                ForEach(MicrophoneMode.allCases) { mode in
                    Button(mode.rawValue) {
                        appState.setMode(mode)
                    }
                    .buttonStyle(.borderless)
                }
            }

            Divider()

            Button(appState.isPanelVisible ? "Hide Panel" : "Show Panel") {
                if appState.isPanelVisible {
                    appState.hidePanelWindow()
                } else {
                    appState.showPanelWindow()
                }
            }

            SettingsLink()

            Divider()

            Button("Quit VoiceFlow") {
                NSApp.terminate(nil)
            }
        }
        .padding(10)
        .frame(minWidth: 220)
    }
}

#Preview {
    MenuBarView()
        .environmentObject(AppState())
}
