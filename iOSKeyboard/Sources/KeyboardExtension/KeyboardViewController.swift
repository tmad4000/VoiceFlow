import AVFoundation
import Speech
import UIKit

final class KeyboardViewController: UIInputViewController {
    private enum SpecialKey: String {
        case shift
        case backspace
        case space
        case returnKey = "return"
        case globe
        case mic
        case numbers
    }

    private let rootStack = UIStackView()
    private let statusLabel = UILabel()
    private var letterButtons: [UIButton] = []
    private weak var shiftButton: UIButton?
    private weak var micButton: UIButton?
    private weak var nextKeyboardButton: UIButton?

    private var isShiftEnabled = false
    private var isTranscribing = false
    private var lastInserted = ""

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupView()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopTranscribing()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        nextKeyboardButton?.isHidden = !needsInputModeSwitchKey
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        updateKeyAppearance()
    }

    private func setupView() {
        view.backgroundColor = UIColor.systemBackground

        rootStack.axis = .vertical
        rootStack.spacing = 6
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.isLayoutMarginsRelativeArrangement = true
        rootStack.layoutMargins = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let statusRow = UIStackView()
        statusRow.axis = .horizontal
        statusRow.spacing = 8
        statusRow.alignment = .center

        statusLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = "Ready"
        statusRow.addArrangedSubview(statusLabel)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusRow.addArrangedSubview(spacer)

        rootStack.addArrangedSubview(statusRow)

        let row1 = makeKeyRow(keys: ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"])
        let row2 = makeKeyRow(keys: ["a", "s", "d", "f", "g", "h", "j", "k", "l"])
        let row3 = makeKeyRow(keys: ["shift", "z", "x", "c", "v", "b", "n", "m", "backspace"], distributesEqually: false)
        let row4 = makeBottomRow()

        rootStack.addArrangedSubview(row1)
        rootStack.addArrangedSubview(row2)
        rootStack.addArrangedSubview(row3)
        rootStack.addArrangedSubview(row4)

        updateKeyAppearance()
    }

    private func makeKeyRow(keys: [String], distributesEqually: Bool = true) -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.distribution = distributesEqually ? .fillEqually : .fillProportionally

        for key in keys {
            let button = makeKeyButton(title: key)
            if let special = SpecialKey(rawValue: key) {
                button.accessibilityIdentifier = special.rawValue
                configureSpecialKey(button, type: special)
            } else {
                button.accessibilityIdentifier = key
                letterButtons.append(button)
            }
            row.addArrangedSubview(button)
        }

        return row
    }

    private func makeBottomRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.distribution = .fillProportionally

        let globe = makeKeyButton(title: "🌐")
        globe.accessibilityIdentifier = SpecialKey.globe.rawValue
        configureSpecialKey(globe, type: .globe)
        nextKeyboardButton = globe

        let space = makeKeyButton(title: "space")
        space.accessibilityIdentifier = SpecialKey.space.rawValue
        configureSpecialKey(space, type: .space)

        let returnKey = makeKeyButton(title: "return")
        returnKey.accessibilityIdentifier = SpecialKey.returnKey.rawValue
        configureSpecialKey(returnKey, type: .returnKey)

        let mic = makeKeyButton(title: "mic")
        mic.accessibilityIdentifier = SpecialKey.mic.rawValue
        configureSpecialKey(mic, type: .mic)
        micButton = mic

        row.addArrangedSubview(globe)
        row.addArrangedSubview(space)
        row.addArrangedSubview(returnKey)
        row.addArrangedSubview(mic)

        globe.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        returnKey.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
        mic.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        space.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true

        return row
    }

    private func makeKeyButton(title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .medium)
        button.setTitleColor(.label, for: .normal)
        button.backgroundColor = UIColor.secondarySystemBackground
        button.layer.cornerRadius = 6
        button.layer.masksToBounds = true
        button.heightAnchor.constraint(equalToConstant: 42).isActive = true
        button.addTarget(self, action: #selector(handleKeyPress(_:)), for: .touchUpInside)
        return button
    }

    private func configureSpecialKey(_ button: UIButton, type: SpecialKey) {
        switch type {
        case .shift:
            button.setTitle("shift", for: .normal)
            shiftButton = button
        case .backspace:
            button.setTitle("⌫", for: .normal)
        case .space:
            button.setTitle("space", for: .normal)
        case .returnKey:
            button.setTitle("return", for: .normal)
        case .globe:
            button.setTitle("🌐", for: .normal)
        case .mic:
            button.setTitle("mic", for: .normal)
        case .numbers:
            button.setTitle("123", for: .normal)
        }
    }

    private func updateKeyAppearance() {
        let isUppercase = isShiftEnabled
        for button in letterButtons {
            guard let value = button.accessibilityIdentifier else { continue }
            let title = isUppercase ? value.uppercased() : value.lowercased()
            button.setTitle(title, for: .normal)
        }

        if let shiftButton {
            if isShiftEnabled {
                shiftButton.backgroundColor = UIColor.systemBlue
                shiftButton.setTitleColor(.white, for: .normal)
            } else {
                shiftButton.backgroundColor = UIColor.secondarySystemBackground
                shiftButton.setTitleColor(.label, for: .normal)
            }
        }

        if let micButton {
            micButton.backgroundColor = isTranscribing ? UIColor.systemRed : UIColor.secondarySystemBackground
            micButton.setTitleColor(isTranscribing ? .white : .label, for: .normal)
        }
    }

    @objc private func handleKeyPress(_ sender: UIButton) {
        guard let identifier = sender.accessibilityIdentifier else { return }

        if let special = SpecialKey(rawValue: identifier) {
            handleSpecialKey(special)
        } else {
            insertCharacter(identifier)
        }
    }

    private func insertCharacter(_ character: String) {
        let text = isShiftEnabled ? character.uppercased() : character.lowercased()
        textDocumentProxy.insertText(text)
        if isShiftEnabled {
            isShiftEnabled = false
            updateKeyAppearance()
        }
    }

    private func handleSpecialKey(_ key: SpecialKey) {
        switch key {
        case .shift:
            isShiftEnabled.toggle()
            updateKeyAppearance()
        case .backspace:
            textDocumentProxy.deleteBackward()
        case .space:
            textDocumentProxy.insertText(" ")
        case .returnKey:
            textDocumentProxy.insertText("\n")
        case .globe:
            advanceToNextInputMode()
        case .mic:
            toggleTranscription()
        case .numbers:
            break
        }
    }

    private func toggleTranscription() {
        if isTranscribing {
            stopTranscribing()
        } else {
            startTranscribing()
        }
    }

    private func startTranscribing() {
        guard !isTranscribing else { return }

        guard hasFullAccess else {
            statusLabel.text = "Enable Full Access to use the microphone"
            return
        }

        guard let speechRecognizer else {
            statusLabel.text = "Speech recognizer unavailable"
            return
        }

        if !speechRecognizer.isAvailable {
            statusLabel.text = "Speech recognizer unavailable"
            return
        }

        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus != .authorized {
            statusLabel.text = "Requesting speech permission"
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if status == .authorized {
                        self.startTranscribing()
                    } else {
                        self.statusLabel.text = "Speech permission denied"
                    }
                }
            }
            return
        }

        let recordPermission = AVAudioSession.sharedInstance().recordPermission
        if recordPermission != .granted {
            statusLabel.text = "Requesting microphone permission"
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.startTranscribing()
                    } else {
                        self.statusLabel.text = "Microphone permission denied"
                    }
                }
            }
            return
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest else {
                statusLabel.text = "Unable to start speech recognition"
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

            isTranscribing = true
            statusLabel.text = "Listening…"
            updateKeyAppearance()

            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    self.handleTranscription(result)
                }
                if error != nil || result?.isFinal == true {
                    self.stopTranscribing()
                }
            }
        } catch {
            statusLabel.text = "Audio session failed"
            stopTranscribing()
        }
    }

    private func handleTranscription(_ result: SFSpeechRecognitionResult) {
        let text = result.bestTranscription.formattedString
        replaceInsertedText(with: text)
        if result.isFinal {
            lastInserted = ""
        }
    }

    private func replaceInsertedText(with newText: String) {
        guard newText != lastInserted else { return }
        if !lastInserted.isEmpty {
            deleteBackward(times: lastInserted.count)
        }
        textDocumentProxy.insertText(newText)
        lastInserted = newText
    }

    private func deleteBackward(times: Int) {
        guard times > 0 else { return }
        for _ in 0..<times {
            textDocumentProxy.deleteBackward()
        }
    }

    private func stopTranscribing() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        isTranscribing = false
        statusLabel.text = "Ready"
        updateKeyAppearance()
        lastInserted = ""
    }
}
