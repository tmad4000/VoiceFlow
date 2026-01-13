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

            if appState.microphoneMode == .on {
                Divider()
                Text("Active Behavior")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 5)

                ForEach(ActiveBehavior.allCases) { behavior in
                    Button {
                        appState.saveActiveBehavior(behavior)
                    } label: {
                        HStack {
                            Image(systemName: appState.activeBehavior == behavior ? "checkmark" : "")
                                .frame(width: 16)
                            Text(behavior.rawValue)
                        }
                    }
                    .buttonStyle(.borderless)
                }

                Divider()
                Text("Dictation Model")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 5)

                ForEach(DictationProvider.allCases) { provider in
                    Button {
                        appState.saveDictationProvider(provider)
                    } label: {
                        HStack {
                            Image(systemName: appState.dictationProvider == provider ? "checkmark" : "")
                                .frame(width: 16)
                            Text(provider.displayName)
                        }
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
