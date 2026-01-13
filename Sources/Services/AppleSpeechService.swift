import Foundation
import Speech
import os.log

private let logger = Logger(subsystem: "com.voiceflow", category: "AppleSpeechService")

class AppleSpeechService: NSObject, ObservableObject {
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    @Published var isConnected = false // Apple speech is "connected" when recognition is active
    @Published var latestTurn: TranscriptTurn?
    @Published var errorMessage: String?

    var supportsOnDeviceRecognition: Bool {
        speechRecognizer?.supportsOnDeviceRecognition == true
    }
    
    private var transcribeMode = true
    private var lastTranscript = ""
    private var turnOrder = 0
    private var lastAddsPunctuation = true
    private var utteranceConfig: UtteranceConfig = .default
    private var silenceTimer: Timer?
    
    func setTranscribeMode(_ enabled: Bool) {
        transcribeMode = enabled
    }

    func setUtteranceConfig(_ config: UtteranceConfig) {
        utteranceConfig = config
    }
    
    func connect() {
        // No-op for Apple speech as it doesn't need a persistent connection like WebSocket
        // but we might want to start the recognition task here if we want it to be ready
    }
    
    func disconnect() {
        stopRecognition()
    }
    
    func sendAudio(_ data: Data) {
        // Convert PCM data back to AVAudioPCMBuffer and append to recognitionRequest
        // This is a bit complex. Alternatively, AppleSpeechService could manage its own capture.
        // But to keep it consistent, let's try to feed it data.
        
        guard let recognitionRequest = recognitionRequest else { return }
        
        // This assumes data is 16kHz mono Int16 as provided by AudioCaptureManager
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        
        data.withUnsafeBytes { (rawBufferPointer: UnsafeRawBufferPointer) in
            if let address = rawBufferPointer.baseAddress {
                let int16Pointer = address.assumingMemoryBound(to: Int16.self)
                buffer.int16ChannelData?[0].update(from: int16Pointer, count: Int(frameCount))
            }
        }
        
        recognitionRequest.append(buffer)
    }
    
    func startRecognition(addsPunctuation: Bool) {
        lastAddsPunctuation = addsPunctuation
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            errorMessage = "Speech recognizer not available"
            isConnected = false
            return
        }
        stopRecognition()

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }
        
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.addsPunctuation = addsPunctuation
        
        if speechRecognizer.supportsOnDeviceRecognition == true {
            recognitionRequest.requiresOnDeviceRecognition = true
            logger.info("Using on-device recognition")
        } else {
            logger.warning("On-device recognition not supported, may fail if offline")
        }
        
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            
            if let result = result {
                self.resetSilenceTimer()
                
                let transcript = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                
                // Map SFSpeech results to TranscriptTurn
                // Apple doesn't provide words with isFinal per word in the same way,
                // so we'll simulate it.
                
                let words = result.bestTranscription.segments.map { segment in
                    TranscriptWord(
                        text: segment.substring,
                        isFinal: isFinal, // In SFSpeech, segments don't have individual isFinal
                        startTime: segment.timestamp,
                        endTime: segment.timestamp + segment.duration
                    )
                }
                
                let turn = TranscriptTurn(
                    transcript: transcript,
                    words: words,
                    endOfTurn: isFinal,
                    isFormatted: isFinal, // We'll treat final as formatted for simplicity
                    turnOrder: self.turnOrder,
                    utterance: transcript
                )
                
                DispatchQueue.main.async {
                    self.latestTurn = turn
                    if isFinal {
                        self.stopSilenceTimer()
                        self.turnOrder += 1
                        // Restart recognition after a final result to keep it "streaming"
                        self.restartRecognition()
                    }
                }
            }
            
            if let error = error {
                // If we forced end, we might get a generic error or just finish.
                // Ignore "Success" error or cancelled if we triggered it.
                logger.error("Recognition error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isConnected = false
                    self.stopSilenceTimer()
                }
            }
        }

        DispatchQueue.main.async {
            self.isConnected = true
        }
    }
    
    private func resetSilenceTimer() {
        stopSilenceTimer()
        let interval = Double(utteranceConfig.silenceThresholdMs) / 1000.0
        // Use a slightly longer timer than strictly VAD to avoid cutting off mid-sentence breath
        // Apple's VAD is internal, but we want to cut it when *text* stops changing?
        // Actually, this result block fires on text changes.
        // If the user stops talking, we stop getting results.
        // So this timer logic is correct: if no new result for X seconds, finalize.
        silenceTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.handleSilenceTimeout()
        }
    }
    
    private func stopSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }
    
    private func handleSilenceTimeout() {
        logger.info("Silence timeout - forcing end of audio")
        recognitionRequest?.endAudio()
    }
    
    private func restartRecognition() {
        // Delay slightly to ensure clean state
        let addsPunctuation = lastAddsPunctuation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.startRecognition(addsPunctuation: addsPunctuation)
        }
    }
    
    func stopRecognition() {
        stopSilenceTimer()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        isConnected = false
    }
    
    func forceEndUtterance() {
        stopSilenceTimer()
        recognitionRequest?.endAudio()
        // We'll restart in the completion handler
    }
}
