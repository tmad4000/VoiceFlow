import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VoiceFlow")
                .font(.headline)

            ForEach(MicrophoneMode.allCases) { mode in
                Button {
                    appState.setMode(mode)
                } label: {
                    HStack {
                        Image(systemName: appState.microphoneMode == mode ? "checkmark" : "")
                            .frame(width: 16)
                        Text(mode.rawValue)
                    }
                }
                .buttonStyle(.borderless)
            }

            Divider()

            Button(appState.isPanelVisible ? "Hide Panel" : "Show Panel") {
                if appState.isPanelVisible {
                    appState.hidePanelWindow()
                } else {
                    appState.showPanelWindow()
                }
            }

            Button("Settings...") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }

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
