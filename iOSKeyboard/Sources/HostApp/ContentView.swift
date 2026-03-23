import SwiftUI

struct ContentView: View {
    @StateObject private var permissions = PermissionsManager()
    @StateObject private var dictationViewModel = DictationViewModel()
    @EnvironmentObject private var router: HostRouter

    var body: some View {
        NavigationStack {
            if router.route == .dictation {
                DictationView(viewModel: dictationViewModel) {
                    router.route = .home
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("VoiceFlow Keyboard")
                            .font(.largeTitle.weight(.semibold))

                        Text("Enable the keyboard and grant permissions to use live dictation in any app.")
                            .font(.body)
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Setup steps")
                                .font(.headline)
                            Text("1. Open Settings → General → Keyboard → Keyboards.")
                            Text("2. Tap “Add New Keyboard…” and select “VoiceFlow Keyboard”.")
                            Text("3. Tap “VoiceFlow Keyboard” and enable Full Access.")
                        }
                        .font(.body)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Permissions")
                                .font(.headline)
                            Text("Speech: \(permissions.speechStatusText)")
                            Text("Microphone: \(permissions.microphoneStatusText)")
                        }
                        .font(.body)

                        Button(action: { permissions.requestPermissions() }) {
                            Text("Request Permissions")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }

                        Button(action: { router.route = .dictation }) {
                            Text("Open Dictation")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                    }
                    .padding(20)
                }
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    permissions.refresh()
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(HostRouter())
}
