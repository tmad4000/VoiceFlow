# AssemblyAI API Research: Dynamic Vocabulary & Optimization

*Research conducted: 2025-12-27*

## Summary

AssemblyAI supports dynamic vocabulary modification entirely via API (no website needed). Vocabulary can be modified per-request or mid-stream. There is no account-level persistent vocabulary storage.

---

## Dynamic Vocabulary Options

### Streaming (Real-time) - `keyterms_prompt`

**At connection time:**
```python
CONNECTION_PARAMS = {
    "sample_rate": 16000,
    "keyterms_prompt": json.dumps(["term1", "term2", "term3"])
}
```

**Mid-stream update via WebSocket:**
```python
# Raw WebSocket
websocket.send('{"type": "UpdateConfiguration", "keyterms_prompt": ["new_term1", "new_term2"]}')

# Python SDK
client.update_configuration(keyterms_prompt=["new_term1", "new_term2"])

# Clear all keyterms
client.update_configuration(keyterms_prompt=[])
```

**Limits:**
- Max 100 terms per session
- Each term ≤ 50 characters
- Updates take effect immediately
- Cost: $0.04/hour extra

### Pre-recorded/Batch - `word_boost`

```python
json = {
    "audio_url": "...",
    "word_boost": ["custom term", "another phrase"],
    "boost_param": "high"  # low, default, or high
}
```

**Limits:**
- Max 1,000 keywords/phrases
- Each phrase ≤ 6 words
- Words should be in spoken form ("triple a" not "aaa")

---

## Vocabulary Limits Summary

| Mode | Feature | Max Terms | Max Length per Term |
|------|---------|-----------|---------------------|
| Streaming | `keyterms_prompt` | 100 | 50 chars |
| Pre-recorded (SLAM-1) | `keyterms_prompt` | 1,000 | 6 words |
| Pre-recorded (Universal) | `keyterms_prompt` | 200 (Beta) | — |
| Pre-recorded | `word_boost` | 1,000 | 6 words |

---

## End-of-Utterance / Pause Time Configuration

### Basic Streaming

```python
transcriber = aai.RealtimeTranscriber(
    sample_rate=16000,
    end_utterance_silence_threshold=300  # milliseconds, adjustable mid-session
)

# Force end utterance manually
transcriber.force_end_utterance()
```

### Universal-Streaming (Semantic Turn Detection)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `end_of_turn_confidence_threshold` | 0.7 | Higher = wait longer for certainty |
| `min_end_of_turn_silence_when_confident` | 160ms | Silence after confident turn-end |
| `max_turn_silence` | — | Acoustic fallback max silence |

**Recommendations:**
- Voice agents (1 speaker): use defaults
- Live captioning (multi-speaker): set `min_end_of_turn_silence_when_confident` to 560ms

---

## Latency Optimization

### Baseline Performance
- AssemblyAI Universal-Streaming: ~300ms P50, ~1000ms P99
- 41% faster median latency than Deepgram Nova-3

### Optimization Techniques

#### 1. Disable Formatting (biggest win)
```python
CONNECTION_PARAMS = {
    "format_turns": False,  # Skip formatting, get raw text faster
    "sample_rate": 16000
}
```

#### 2. Lower End-of-Turn Thresholds
```python
{
    "end_of_turn_confidence_threshold": 0.5,  # default 0.7, lower = faster
    "min_end_of_turn_silence_when_confident": 100  # default 160ms
}
```

#### 3. Pre-emptive Processing with `utterance`
The `utterance` field arrives before `end_of_turn`. Start LLM processing early to save 200-500ms:

```python
def on_data(transcript):
    if transcript.utterance:
        # Start LLM generation NOW, don't wait for end_of_turn
        start_llm_response(transcript.text)
```

#### 4. Tuning Presets
- **Aggressive** - fastest, may cut off speech
- **Balanced** - default
- **Conservative** - waits longer, fewer interruptions

---

## Account-Level Persistence

**Not available** for standard API. Vocabulary must be passed per-request.

**Workaround:** Store vocabulary in a config file and load with each request.

**Enterprise option:** Custom Models can store vocabulary permanently but requires training.

---

## Pricing

| Feature | Cost |
|---------|------|
| Base streaming | $0.15/hour |
| Keyterms Prompting add-on | $0.04/hour |
| **Total with keyterms** | $0.19/hour |

---

## Sources

- [Keyterms Prompting Documentation](https://www.assemblyai.com/docs/universal-streaming/keyterms-prompting)
- [Streaming Keyterms Blog Post](https://www.assemblyai.com/blog/streaming-keyterms-prompting)
- [Turn Detection Documentation](https://www.assemblyai.com/docs/universal-streaming/turn-detection)
- [Voice Agent Best Practices](https://www.assemblyai.com/docs/voice-agent-best-practices)
- [Pre-recorded Key Terms](https://www.assemblyai.com/docs/speech-to-text/pre-recorded-audio/key-terms-prompting)
- [Custom Vocabulary FAQ](https://www.assemblyai.com/docs/faq/what-is-the-difference-between-custom-vocabulary-and-custom-spelling)
- [Lower Latency Blog](https://www.assemblyai.com/blog/lower-latency-new-pricing)
