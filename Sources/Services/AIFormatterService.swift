import Foundation

/// AI-powered text formatting service using Claude Haiku
/// Provides context-aware capitalization and punctuation fixes
@MainActor
class AIFormatterService: ObservableObject {

    // MARK: - Configuration

    struct Config {
        var enabled: Bool = false
        var apiKey: String = ""
        var model: String = "claude-3-5-haiku-20241022"  // Fast and cheap
        var maxLatencyMs: Int = 300  // Skip formatting if slower than this
        var onlyFixEdgeCases: Bool = true  // Don't reformat everything, just fix issues
    }

    // MARK: - Properties

    @Published var config = Config()
    @Published var lastLatencyMs: Int = 0
    @Published var isProcessing: Bool = false

    private let focusContext: FocusContextManager
    private let session = URLSession.shared

    // MARK: - Initialization

    init(focusContext: FocusContextManager) {
        self.focusContext = focusContext
        loadConfig()
    }

    private func loadConfig() {
        let defaults = UserDefaults.standard
        config.enabled = defaults.bool(forKey: "ai_formatter_enabled")
        config.apiKey = defaults.string(forKey: "anthropic_api_key") ?? ""
    }

    func saveConfig() {
        let defaults = UserDefaults.standard
        defaults.set(config.enabled, forKey: "ai_formatter_enabled")
        defaults.set(config.apiKey, forKey: "anthropic_api_key")
    }

    // MARK: - Formatting

    /// Format text with AI assistance
    /// Returns the original text if formatting fails or times out
    func format(_ rawText: String) async -> String {
        guard config.enabled, !config.apiKey.isEmpty else {
            return rawText
        }

        let context = focusContext.getFormattingContext()
        let startTime = Date()

        isProcessing = true
        defer { isProcessing = false }

        do {
            let formatted = try await callClaudeAPI(rawText: rawText, context: context)
            let latency = Int(Date().timeIntervalSince(startTime) * 1000)
            lastLatencyMs = latency

            NSLog("[AIFormatter] Formatted in \(latency)ms: \"\(rawText)\" → \"\(formatted)\"")

            // If it took too long, log warning but still use result
            if latency > config.maxLatencyMs {
                NSLog("[AIFormatter] Warning: Latency \(latency)ms exceeded target \(config.maxLatencyMs)ms")
            }

            return formatted
        } catch {
            NSLog("[AIFormatter] Error: \(error.localizedDescription)")
            return rawText
        }
    }

    // MARK: - Claude API

    private func callClaudeAPI(rawText: String, context: FocusContextManager.FormattingContext) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = Double(config.maxLatencyMs) / 1000.0 + 0.5  // Add buffer

        let prompt = buildPrompt(rawText: rawText, context: context)

        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": 256,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw FormatterError.apiError(statusCode: statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw FormatterError.parseError
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func buildPrompt(rawText: String, context: FocusContextManager.FormattingContext) -> String {
        var prompt = """
        Fix capitalization and punctuation for this voice-dictated text.

        Context:
        - App: \(context.appName ?? "Unknown")
        - Style: \(context.formattingStyle)
        """

        if context.isNewSegment {
            prompt += "\n- This is the START of a new text session (capitalize first word)"
        } else if let previousEnding = context.previousEnding {
            prompt += "\n- Previous text ended with: \"\(previousEnding)\""

            // Give specific guidance based on previous ending
            if previousEnding.hasSuffix(".") || previousEnding.hasSuffix("!") || previousEnding.hasSuffix("?") {
                prompt += "\n- Previous sentence is complete (capitalize this)"
            } else if previousEnding.hasSuffix(",") {
                prompt += "\n- Previous sentence continues (don't capitalize unless proper noun)"
            }
        }

        if !context.recentUtterances.isEmpty && context.recentUtterances.count > 1 {
            let recent = context.recentUtterances.suffix(3).joined(separator: " | ")
            prompt += "\n- Recent context: \"\(recent)\""
        }

        prompt += """


        Raw input: "\(rawText)"

        Rules:
        1. Only fix obvious capitalization/punctuation errors
        2. Don't add words or change meaning
        3. Preserve intentional formatting (like code)
        4. For terminal/code: prefer lowercase unless clear sentence
        5. For chat: casual punctuation is fine

        Output ONLY the corrected text, nothing else:
        """

        return prompt
    }

    // MARK: - On-Demand Text Improvement

    /// Improve selected text - fixes punctuation, capitalization, and minor grammar issues
    /// This is called on-demand via "improve that" voice command, not inline
    /// Returns the original text if improvement fails
    func improve(_ text: String) async -> String {
        guard !config.apiKey.isEmpty else {
            NSLog("[AIFormatter] Cannot improve: no API key configured")
            return text
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return text
        }

        let startTime = Date()
        isProcessing = true
        defer { isProcessing = false }

        do {
            let improved = try await callImproveAPI(text: text)
            let latency = Int(Date().timeIntervalSince(startTime) * 1000)
            lastLatencyMs = latency
            NSLog("[AIFormatter] Improved in \(latency)ms: \"\(text.prefix(50))...\" → \"\(improved.prefix(50))...\"")
            return improved
        } catch {
            NSLog("[AIFormatter] Improve error: \(error.localizedDescription)")
            return text
        }
    }

    private func callImproveAPI(text: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 10.0  // Allow more time for improvement

        let prompt = """
        Improve this voice-dictated text by fixing:
        - Capitalization (sentence starts, proper nouns)
        - Punctuation (periods, commas, question marks)
        - Minor grammar issues
        - Run-on sentences (add appropriate punctuation)

        Do NOT:
        - Change the meaning or wording
        - Add or remove content
        - Rewrite sentences
        - Add markdown or formatting

        Input text:
        \(text)

        Output ONLY the improved text, nothing else:
        """

        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": 1024,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw FormatterError.apiError(statusCode: statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let resultText = firstBlock["text"] as? String else {
            throw FormatterError.parseError
        }

        return resultText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Errors

    enum FormatterError: Error {
        case apiError(statusCode: Int)
        case parseError
        case timeout
    }
}

// MARK: - Quick Formatting Heuristics (No API)

extension AIFormatterService {

    /// Fast local heuristics - use when API is disabled or for obvious cases
    func quickFormat(_ text: String, context: FocusContextManager.FormattingContext) -> String {
        var result = text

        // Don't touch terminal/code input
        if context.appCategory == .terminal || context.appCategory == .codeEditor {
            return text
        }

        // For document and chat contexts, always capitalize the first letter of each utterance
        // Each utterance from ASR typically represents a new thought/sentence
        // Even without sentence-ending punctuation from the previous utterance
        if context.isNewSegment {
            // First utterance in a new app focus segment
            result = capitalizeFirst(result)
            NSLog("[AIFormatter] Capitalizing (new segment)")
        } else if let prev = context.previousEnding {
            if prev.hasSuffix(".") || prev.hasSuffix("!") || prev.hasSuffix("?") {
                // Previous utterance ended with sentence-ending punctuation
                result = capitalizeFirst(result)
                NSLog("[AIFormatter] Capitalizing (after punctuation: \"\(prev)\")")
            } else {
                // Previous utterance didn't end with punctuation, but this is still a new utterance
                // In natural speech, each pause/utterance typically starts a new thought
                result = capitalizeFirst(result)
                NSLog("[AIFormatter] Capitalizing (new utterance, prev: \"\(prev)\")")
            }
        } else {
            // No previous utterance but not marked as new segment (edge case)
            result = capitalizeFirst(result)
            NSLog("[AIFormatter] Capitalizing (fallback)")
        }

        return result
    }

    private func capitalizeFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
