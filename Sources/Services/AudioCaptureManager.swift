import Foundation
import AVFoundation
import Accelerate
import CoreAudio

/// Manages microphone audio capture for streaming to AssemblyAI
/// Captures mono 16-bit PCM audio at 16kHz
class AudioCaptureManager: NSObject {
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private let targetSampleRate: Double = 16000
    private let bufferSize: AVAudioFrameCount = 1024
    private let preferredDeviceID: String?

    /// Callback for audio data ready to send
    var onAudioData: ((Data) -> Void)?

    /// Callback for audio level (0.0 to 1.0)
    var onAudioLevel: ((Float) -> Void)?

    private var isCapturing = false

    init(deviceID: String? = nil) {
        self.preferredDeviceID = deviceID
        super.init()
    }

    func startCapture() {
        guard !isCapturing else { return }

        do {
            audioEngine = AVAudioEngine()
            guard let audioEngine = audioEngine else { return }
            
            // Configure input device if specified
            if let deviceID = preferredDeviceID {
                // Find the device
                let discoverySession = AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.builtInMicrophone, .externalUnknown],
                    mediaType: .audio,
                    position: .unspecified
                )
                
                if let device = discoverySession.devices.first(where: { $0.uniqueID == deviceID }) {
                    // We need to set the device on the input node's AU
                    // However, AVAudioEngine automatically uses the system default or whatever is set in AudioUnit
                    // A better way with AVAudioEngine is often to rely on system default or use aggregate device,
                    // but we can try to set the input node's device via Core Audio if needed.
                    // For now, let's use the simpler approach:
                    // If we want to support specific device selection properly with AVAudioEngine,
                    // we often need to set the device for the engine's input node via AudioUnit SetProperty.
                    
                    do {
                        try setInputDevice(device.uniqueID, for: audioEngine.inputNode)
                        print("Set input device to: \(device.localizedName)")
                    } catch {
                        print("Failed to set input device: \(error)")
                        // Fallback to default
                    }
                } else {
                    print("Preferred device \(deviceID) not found, using default")
                }
            }

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
        // Use a more sensitive curve: level = rms^0.5 * 3.0
        // This boosts low signals while keeping high signals bounded
        let level = min(1.0, sqrt(rms) * 3.0)

        // Send to callbacks
        DispatchQueue.main.async { [weak self] in
            self?.onAudioData?(data)
            self?.onAudioLevel?(level)
        }
    }

    private func setInputDevice(_ deviceID: String, for inputNode: AVAudioInputNode) throws {
        let audioUnit = inputNode.audioUnit!
        var deviceID = getAudioDeviceID(from: deviceID)
        
        guard deviceID != kAudioDeviceUnknown else {
            throw NSError(domain: "AudioCaptureManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown device ID"])
        }

        let error = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if error != noErr {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(error), userInfo: nil)
        }
    }

    private func getAudioDeviceID(from uniqueID: String) -> AudioDeviceID {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
        guard status == noErr else { return kAudioDeviceUnknown }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs)
        guard status == noErr else { return kAudioDeviceUnknown }

        for id in deviceIDs {
            var uidString: CFString? = nil
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            
            status = AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &uidString)
            if status == noErr, let uid = uidString as String? {
                if uid == uniqueID {
                    return id
                }
            }
        }

        return kAudioDeviceUnknown
    }

    deinit {
        stopCapture()
    }
}
