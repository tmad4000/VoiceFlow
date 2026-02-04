import AVFoundation
import Speech
import UIKit

final class DictationViewModel: ObservableObject {
    @Published var transcript: String = ""
    @Published var isRecording: Bool = false
    @Published var statusText: String = "Ready"

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private let dictationPasteboardPrefix = "voiceflow-dictation::"

    func refreshPermissions() {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let micStatus = AVAudioSession.sharedInstance().recordPermission
        if speechStatus != .authorized {
            updateStatus("Speech permission required")
        } else if micStatus != .granted {
            updateStatus("Microphone permission required")
        } else {
            updateStatus(isRecording ? "Listening…" : "Ready")
        }
    }

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshPermissions()
            }
        }
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshPermissions()
            }
        }
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard !isRecording else { return }

        guard let speechRecognizer else {
            updateStatus("Speech recognizer unavailable")
            return
        }

        if !speechRecognizer.isAvailable {
            updateStatus("Speech recognizer unavailable")
            return
        }

        ensurePermissions { [weak self] granted in
            guard let self else { return }
            if granted {
                self.beginRecognition()
            } else {
                self.updateStatus("Permissions required")
            }
        }
    }

    func stopRecording() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        isRecording = false
        updateStatus("Ready")
    }

    func copyToPasteboard() {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UIPasteboard.general.string = dictationPasteboardPrefix + trimmed
        updateStatus("Copied. Return to the keyboard to paste.")
    }

    private func beginRecognition() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest else {
                updateStatus("Unable to start speech recognition")
                return
            }

            recognitionRequest.shouldReportPartialResults = true

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()

            isRecording = true
            updateStatus("Listening…")

            recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    self.updateTranscript(result.bestTranscription.formattedString)
                }
                if error != nil || result?.isFinal == true {
                    self.stopRecording()
                }
            }
        } catch {
            updateStatus("Audio session failed")
            stopRecording()
        }
    }

    private func ensurePermissions(_ completion: @escaping (Bool) -> Void) {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus != .authorized {
            updateStatus("Requesting speech permission")
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    if status == .authorized {
                        self?.requestMicrophone(completion)
                    } else {
                        completion(false)
                    }
                }
            }
            return
        }

        requestMicrophone(completion)
    }

    private func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        let recordPermission = AVAudioSession.sharedInstance().recordPermission
        if recordPermission == .granted {
            completion(true)
        } else {
            updateStatus("Requesting microphone permission")
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        }
    }

    private func updateTranscript(_ value: String) {
        DispatchQueue.main.async {
            self.transcript = value
        }
    }

    private func updateStatus(_ value: String) {
        DispatchQueue.main.async {
            self.statusText = value
        }
    }
}
