import SwiftUI

struct DictationView: View {
    @ObservedObject var viewModel: DictationViewModel
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Dictation")
                    .font(.largeTitle.weight(.semibold))
                Spacer()
                Button("Done") {
                    viewModel.stopRecording()
                    onDone()
                }
            }

            Text(viewModel.statusText)
                .font(.subheadline)
                .foregroundColor(.secondary)

            ScrollView {
                Text(viewModel.transcript.isEmpty ? "Your transcription will appear here." : viewModel.transcript)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
            }

            HStack(spacing: 12) {
                Button(action: { viewModel.toggleRecording() }) {
                    Text(viewModel.isRecording ? "Stop" : "Start")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(viewModel.isRecording ? Color.red : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }

                Button(action: { viewModel.copyToPasteboard() }) {
                    Text("Copy to Keyboard")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .disabled(viewModel.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(viewModel.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
            }

            Button("Request Permissions") {
                viewModel.requestPermissions()
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(20)
        .onAppear {
            viewModel.refreshPermissions()
        }
    }
}

#Preview {
    DictationView(viewModel: DictationViewModel(), onDone: {})
}
