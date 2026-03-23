# CLAUDE.md — SiliconValley Theater

## What This Is

A macOS menu bar app that watches Claude Code sessions and generates live comedy commentary voiced by TV characters. Pure Swift, Apple Silicon, 100% local by default.

## Build & Run

```bash
make build                    # → build/SiliconValleyTheater.app
open build/SiliconValleyTheater.app
```

No Xcode project — uses `swiftc` directly via Makefile.

## Architecture Overview

```
JSONL session file → SessionWatcher (kqueue) → EventSummarizer (no LLM)
  → TheaterEngine → theater.md RAG → LLM prompt → Voice synthesis → Playback
```

- **SessionWatcher**: tails the latest Claude Code JSONL file via kqueue (<1ms latency)
- **EventSummarizer**: filters noise, keeps conversation flow (USER → CLAUDE → CHANGED)
- **TheaterEngine**: central orchestrator — batches events, generates dialogue, manages playback
- **TheaterContext**: parses `theater.md` from projects, does keyword-matched RAG for few-shot examples
- **DialogueGenerator**: builds LLM prompts with character context + matched examples
- **DynamicFillerPool**: consume-and-replenish banter pool so the app is never silent

## Key Design Decisions

- **User = show character**: The user is always mapped to a character in the show (Richard for Silicon Valley, Johnny for Schitt's Creek, etc.). Displayed as "You (CharacterName)" in the widget.
- **3-tier voice cache**: clone once → disk cache → phrase cache. After a few sessions, 90%+ of audio is pure disk reads.
- **Pipelined playback**: synthesize line N+1 while line N plays. No gaps.
- **theater.md RAG**: keyword-matched example selection from project-specific configs. The LLM gets the most relevant few-shot example for each event batch.
- **Never silent**: cold opens → context fillers → LLM dialogue → gap fillers → term explainers. Always something playing.

## File Layout

- `Sources/Models/CharacterTheme.swift` — 9 character themes with personalities, catchphrases, few-shot examples, and `userCharacterName`
- `Sources/Models/Config.swift` — settings, per-session theme map, LLM/TTS provider selection
- `Sources/Models/TheaterContext.swift` — theater.md parser + RAG matching
- `Sources/Services/DialogueGenerator.swift` — event summarizer + LLM prompt construction
- `Sources/Views/WidgetView.swift` — Zoom-style floating widget with character tiles
- `Sources/SiliconValleyApp.swift` — menu bar app entry point

## Common Tasks

- **Add a new theme**: Add a `static let` in `CharacterTheme.swift`, include it in `allThemes`, set `userCharacterName`
- **Fix dialogue quality**: Check `DialogueGenerator.swift` — the system prompt, few-shot examples, and event summarization logic
- **Change widget UI**: `WidgetView.swift` — the floating panel layout, character tiles, subtitles
- **theater.md issues**: `TheaterContext.swift` — RAG keyword matching, example selection

## LLM Providers

- **Ollama** (default): local Qwen 2.5 3B — `ollama pull qwen2.5:3b`
- **Groq** (optional): cloud Llama 3.3 70B — free API key from console.groq.com, much better quality

## TTS Providers

- **Pocket TTS** (default): local voice cloning via Python sidecar in `TTSSidecar/`
- **Kokoro**: fast local TTS
- **Fish Audio / Cartesia**: cloud alternatives
