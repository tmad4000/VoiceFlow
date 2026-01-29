import AVFoundation
import Speech
import SwiftUI

@MainActor
final class PermissionsManager: ObservableObject {
    @Published private(set) var speechStatus: SFSpeechRecognizerAuthorizationStatus
    @Published private(set) var microphoneGranted: Bool

    init() {
        speechStatus = SFSpeechRecognizer.authorizationStatus()
        microphoneGranted = AVAudioSession.sharedInstance().recordPermission == .granted
    }

    var speechStatusText: String {
        switch speechStatus {
        case .authorized:
            return "Authorized"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .notDetermined:
            return "Not Determined"
        @unknown default:
            return "Unknown"
        }
    }

    var microphoneStatusText: String {
        microphoneGranted ? "Authorized" : "Not Authorized"
    }

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                self?.speechStatus = status
            }
        }

        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                self?.microphoneGranted = granted
            }
        }
    }
}
