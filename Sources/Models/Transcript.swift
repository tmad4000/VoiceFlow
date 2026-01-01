import Foundation

struct TranscriptWord {
    let text: String
    let isFinal: Bool?
    let startTime: Double?
    let endTime: Double?
    let speaker: Int?

    init(text: String, isFinal: Bool? = nil, startTime: Double? = nil, endTime: Double? = nil, speaker: Int? = nil) {
        self.text = text
        self.isFinal = isFinal
        self.startTime = startTime
        self.endTime = endTime
        self.speaker = speaker
    }
}

struct TranscriptTurn {
    let transcript: String
    let words: [TranscriptWord]
    let endOfTurn: Bool
    let isFormatted: Bool
    let turnOrder: Int?
    let utterance: String?
    let speaker: Int?

    init(transcript: String, words: [TranscriptWord], endOfTurn: Bool, isFormatted: Bool, turnOrder: Int? = nil, utterance: String? = nil, speaker: Int? = nil) {
        self.transcript = transcript
        self.words = words
        self.endOfTurn = endOfTurn
        self.isFormatted = isFormatted
        self.turnOrder = turnOrder
        self.utterance = utterance
        self.speaker = speaker
    }
}
