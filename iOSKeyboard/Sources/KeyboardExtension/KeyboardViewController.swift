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
    private var hasPendingDictation = false
    private let hostAppURL = URL(string: "voiceflowkeyboard://dictation")
    private let dictationPasteboardPrefix = "voiceflow-dictation::"

    override func viewDidLoad() {
        super.viewDidLoad()
        setupView()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        nextKeyboardButton?.isHidden = !needsInputModeSwitchKey
        refreshDictationState()
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
            if hasPendingDictation {
                micButton.backgroundColor = UIColor.systemGreen
                micButton.setTitleColor(.white, for: .normal)
            } else {
                micButton.backgroundColor = UIColor.secondarySystemBackground
                micButton.setTitleColor(.label, for: .normal)
            }
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
            handleMicPress()
        case .numbers:
            break
        }
    }

    private func handleMicPress() {
        if let dictation = consumeDictationFromPasteboard() {
            textDocumentProxy.insertText(dictation)
            statusLabel.text = "Inserted dictation"
            hasPendingDictation = false
            updateKeyAppearance()
            return
        }

        if !hasFullAccess {
            statusLabel.text = "Enable Full Access to paste dictation"
        }

        openHostApp()
    }

    private func openHostApp() {
        guard let hostAppURL else {
            statusLabel.text = "Unable to open VoiceFlow"
            return
        }

        extensionContext?.open(hostAppURL, completionHandler: { [weak self] success in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    self.statusLabel.text = "Dictate in VoiceFlow, then return to paste"
                } else {
                    self.statusLabel.text = "Open VoiceFlow to dictate"
                }
                self.refreshDictationState()
            }
        })
    }

    private func refreshDictationState() {
        if peekDictationFromPasteboard() != nil {
            hasPendingDictation = true
            statusLabel.text = "Dictation ready. Tap mic to paste"
        } else {
            hasPendingDictation = false
            if hasFullAccess {
                statusLabel.text = "Tap mic to dictate in VoiceFlow app"
            } else {
                statusLabel.text = "Enable Full Access for dictation"
            }
        }
        updateKeyAppearance()
    }

    private func peekDictationFromPasteboard() -> String? {
        guard hasFullAccess else { return nil }
        guard let text = UIPasteboard.general.string else { return nil }
        guard text.hasPrefix(dictationPasteboardPrefix) else { return nil }
        return String(text.dropFirst(dictationPasteboardPrefix.count))
    }

    private func consumeDictationFromPasteboard() -> String? {
        guard let dictation = peekDictationFromPasteboard() else { return nil }
        UIPasteboard.general.items = []
        return dictation
    }
}
