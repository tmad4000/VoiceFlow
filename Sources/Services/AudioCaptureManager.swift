import Foundation
import AVFoundation
import Accelerate

/// Manages microphone audio capture for streaming to AssemblyAI
/// Captures mono 16-bit PCM audio at 16kHz
class AudioCaptureManager: NSObject {
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private let targetSampleRate: Double = 16000
    private let bufferSize: AVAudioFrameCount = 1024

    /// Callback for audio data ready to send
    var onAudioData: ((Data) -> Void)?

    /// Callback for audio level (0.0 to 1.0)
    var onAudioLevel: ((Float) -> Void)?

    private var isCapturing = false

    override init() {
        super.init()
    }

    func startCapture() {
        guard !isCapturing else { return }

        do {
            audioEngine = AVAudioEngine()
            guard let audioEngine = audioEngine else { return }

            inputNode = audioEngine.inputNode
            guard let inputNode = inputNode else { return }

            let inputFormat = inputNode.outputFormat(forBus: 0)

            // Create output format: mono 16kHz PCM
            guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: true
            ) else {
                print("Failed to create output format")
                return
            }

            // Create converter for sample rate and format conversion
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                print("Failed to create audio converter")
                return
            }

            // Install tap on input node
            inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, time in
                self?.processAudioBuffer(buffer, converter: converter, outputFormat: outputFormat)
            }

            audioEngine.prepare()
            try audioEngine.start()
            isCapturing = true
            print("Audio capture started")

        } catch {
            print("Failed to start audio capture: \(error)")
        }
    }

    func stopCapture() {
        guard isCapturing else { return }

        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        inputNode = nil
        isCapturing = false
        print("Audio capture stopped")
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, outputFormat: AVAudioFormat) {
        // Calculate output frame capacity based on sample rate ratio
        let ratio = targetSampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            return
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            print("Conversion error: \(error)")
            return
        }

        // Convert to Data
        guard let channelData = outputBuffer.int16ChannelData else { return }
        let frameLength = Int(outputBuffer.frameLength)
        let data = Data(bytes: channelData[0], count: frameLength * MemoryLayout<Int16>.size)

        // Calculate audio level (RMS)
        let samples = channelData[0]
        var sum: Float = 0
        for i in 0..<frameLength {
            let sample = Float(samples[i]) / Float(Int16.max)
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameLength))
        // Convert to 0-1 range with some scaling for better visualization
        // Increased scaling from 4.0 to 8.0 for better sensitivity
        let level = min(1.0, rms * 8.0)

        // Send to callbacks
        DispatchQueue.main.async { [weak self] in
            self?.onAudioData?(data)
            self?.onAudioLevel?(level)
        }
    }

    deinit {
        stopCapture()
    }
}
