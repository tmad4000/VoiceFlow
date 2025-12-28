# Speech APIs & Dictation Research

**Date:** 2024-12-27
**Related Issues:** VoiceFlow-7lt, VoiceFlow-2at, VoiceFlow-0n2

---

## 1. Apple Dictation Architecture

### How Text Insertion Works

Apple's dictation uses the **NSTextInputClient protocol**:

- `setMarkedText` - Inserts provisional "marked" text (grayed/highlighted) that can be replaced as recognition improves
- `insertText` - Commits final text, replacing any marked text

This is the same mechanism as IME for Japanese/Chinese input.

### Terminal Limitation

Terminals typically don't fully implement NSTextInputClient. They accept keystrokes via lower-level mechanisms (CGEventTap), which is why dictation in Terminal looks different - it falls back to simulating keystrokes rather than using marked-text replacement.

### Text Insertion Methods

| Method | Use Case | Rewriting? | App Store OK? |
|--------|----------|------------|---------------|
| NSTextInputClient | Cocoa apps | Yes (marked text) | N/A |
| CGEventTap | Universal (terminals) | No (keystroke sim) | Yes |
| Accessibility API | Read/write context | Yes | No |

---

## 2. Context Awareness Options

### Reading Current Text Field

Apple's native dictation does NOT expose APIs to read surrounding context. Third-party tools use **Accessibility API (AXUIElement)**:

```swift
AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute, ...)
```

This allows reading:
- Full text content of focused field
- Selected text (`kAXSelectedTextAttribute`)
- Cursor position

**Tools using this:** Superwhisper, Typer, Talon

### Detecting Active Application

```swift
NSWorkspace.shared.frontmostApplication?.bundleIdentifier
// "com.apple.Terminal", "com.googlecode.iterm2", etc.
```

---

## 3. macOS 26 SpeechAnalyzer API

Released September 2025, current version 26.2 (December 2025).

### Key Modules

| Module | Purpose | Use Case |
|--------|---------|----------|
| SpeechDetector | Voice Activity Detection | Wake detection |
| SpeechTranscriber | Raw words only | Command recognition |
| DictationTranscriber | Full punctuation/formatting | Natural language dictation |

### Performance vs Whisper

From MacStories testing (34-min video):
- **Apple SpeechTranscriber:** 45 seconds
- **MacWhisper V3 Turbo Large:** 1 min 41 sec
- **MacWhisper V2 Large:** 3 min 55 sec

**Apple is 2.2x faster** with comparable quality.

### Swift Example

```swift
import Speech

// For command detection (raw words, fast)
let commandTranscriber = SpeechTranscriber(
    locale: .current,
    preset: .offlineTranscription
)

// For full dictation (punctuation, formatting)
let dictationTranscriber = DictationTranscriber(locale: .current)

let analyzer = SpeechAnalyzer(modules: [commandTranscriber])
```

### Current Limitations

- SpeechDetector has API bug (doesn't conform to SpeechModule yet)
- For always-on listening, dedicated wake word engines still recommended

---

## 4. Command Detection Libraries

### Comparison Table

| Library | Latency | Model Size | Custom Commands | Platform | License |
|---------|---------|------------|-----------------|----------|---------|
| **Porcupine** | <100ms | ~2MB | Yes (seconds) | All | Free non-commercial |
| **openWakeWord** | ~80ms | ~50MB | Yes (Colab) | Python | Apache 2.0 |
| **Vosk** | Real-time | 50MB (small) | Vocabulary config | All | Apache 2.0 |
| **microWakeWord** | Ultra-low | <1MB | Yes | ESP32 | Open source |
| **Apple SpeechTranscriber** | Fast | System | Built-in | macOS 26 | Native |

### Porcupine (Picovoice)

- Train custom wake words in seconds by typing them
- <4% CPU on Raspberry Pi 3
- 97%+ accuracy, <1 false alarm/10 hours
- Free for personal/non-commercial
- Swift SDK available

### openWakeWord

- Fully open source (Apache 2.0)
- Train via Google Colab notebook in <1 hour
- Not fast enough for ultra-low-power edge devices
- ~50MB memory footprint

### Vosk

- Full vocabulary recognition, not just wake words
- Configurable vocabulary for command sets
- Streaming API with zero-latency response
- Bindings for Python, Swift, Java, C#, Node, Go, Rust

---

## 5. Talon Conformer

Talon's built-in speech recognition engine.

### Accuracy

- ~20% more accurate than previous wav2letter gen2
- Competitive with Dragon
- Competitive with Whisper on benchmarks

### Benchmark vs Whisper Large (2022)

| Test Set | Talon 1B | Whisper Large |
|----------|----------|---------------|
| LibriSpeech clean | 2.40 | 2.7 |
| LibriSpeech other | 5.63 | 5.6 |
| Common Voice | 8.86 | 9.5 |

### Notes

- English only (German prototype exists)
- Optimized for voice coding commands
- Uses ~1GB less RAM than older wav2letter

---

## 6. AssemblyAI vs Apple Comparison

### Accuracy

| Model | WER | Notes |
|-------|-----|-------|
| AssemblyAI Universal-2 | ~10% | Best-in-class, 600M params |
| Whisper Large-v3 | ~12% | 1550M params |
| Apple SpeechAnalyzer | ~mid-tier Whisper | On-device |

### AssemblyAI Advantages

- 16-22% lower error rate than Whisper
- 30% fewer hallucinations
- Better proper noun recognition
- 99+ languages

### Apple Advantages

- 100% on-device (privacy)
- No API costs
- No network latency (2.2x faster)
- No rate limits for on-device

---

## 7. LLM Post-Processing Latency

For punctuation/formatting fixes:

| Model | Time to First Token | Total (~50 tokens) |
|-------|---------------------|-------------------|
| GPT-4o-mini | ~560ms | ~1-1.5 sec |
| Claude Haiku | ~300-500ms | ~1 sec |
| Gemini Flash | ~320ms | ~500-700ms |
| Local (Llama 3.2 1B) | ~50-100ms | ~200-500ms |

---

## 8. Permissions: Accessibility vs Input Monitoring

| Aspect | Accessibility (AXUIElement) | Input Monitoring (CGEventTap) |
|--------|----------------------------|------------------------------|
| **Purpose** | Read/query UI elements | Monitor/modify keyboard/mouse |
| **Speed** | Slightly higher overhead (IPC) | Very fast (kernel-level) |
| **Sandbox** | NOT allowed in App Store | Allowed since macOS 10.15 |
| **For VoiceFlow** | Read context from text field | Post keystrokes to type text |

---

## 9. Recommended Architecture

### Hybrid Approach

```
┌─────────────────────────────────────────────────────────────┐
│  LAYER 1: Always-On Wake Word (Porcupine/openWakeWord)      │
│  - <4% CPU, designed for 24/7                               │
│  - No rate limits                                           │
│  - Detects: "Hey Flow", "Computer", etc.                    │
└──────────────────────────┬──────────────────────────────────┘
                           │ Triggers...
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  LAYER 2: Apple SpeechTranscriber (command mode)            │
│  - Fast, on-device, no limits during active session         │
│  - Listens for commands: "on", "off", "sleep", "stop"       │
└──────────────────────────┬──────────────────────────────────┘
                           │ If dictation requested...
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  LAYER 3: AssemblyAI (high-accuracy transcription)          │
│  - Keep for quality dictation                               │
│  - Optional LLM post-processing for context-aware punct     │
└─────────────────────────────────────────────────────────────┘
```

### App Store Strategy

**Lite (App Store):**
- Basic dictation, voice commands
- Input Monitoring only

**Pro (Direct Distribution):**
- Context-aware punctuation
- Inline rewriting
- Accessibility API features

---

## Sources

### Apple Documentation
- [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [WWDC25: SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)
- [NSTextInputClient](https://developer.apple.com/documentation/appkit/nstextinputclient)

### Third-Party Tools
- [Porcupine](https://picovoice.ai/platform/porcupine/)
- [openWakeWord](https://github.com/dscripka/openWakeWord)
- [Vosk](https://alphacephei.com/vosk/)
- [Superwhisper](https://superwhisper.com/)
- [Typer](https://github.com/halftone-dev/Typer)

### Benchmarks
- [MacStories: Apple vs Whisper](https://www.macstories.net/stories/hands-on-how-apples-new-speech-apis-outpace-whisper-for-lightning-fast-transcription/)
- [AssemblyAI Benchmarks](https://www.assemblyai.com/benchmarks)
- [Artificial Analysis](https://artificialanalysis.ai/models/gpt-4o-mini)

### Talon
- [Talon Speech Engines Wiki](https://talon.wiki/Resource%20Hub/Speech%20Recognition/speech%20engines)
- [Talon Conformer Release](https://www.patreon.com/posts/talon-v0-2-1-56485850)
