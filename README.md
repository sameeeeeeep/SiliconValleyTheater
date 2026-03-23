# SiliconValley Theater

**Live comedy commentary for your Claude Code sessions — voiced by TV characters.**

You're coding. Claude Code is doing its thing. But instead of watching a terminal scroll in silence, Gilfoyle and Dinesh are roasting your variable names. David Rose is having a breakdown about your merge conflicts. Moira is calling the codebase "bébé."

100% local. Your code never leaves your machine.

https://github.com/user-attachments/assets/demo-placeholder

---

## How It Works

The app watches your Claude Code session in real time, understands what's happening (user questions, code changes, build results), and generates character dialogue that narrates the session — synthesized with cloned voices and played through a floating Zoom-style widget.

```
Claude Code session (JSONL) → Event watcher (kqueue, <1ms)
    → Smart filter (keeps conversation, drops noise)
    → LLM generates dialogue (Qwen 3B local or Groq 70B cloud)
    → Voice synthesis (cloned voices via Pocket TTS)
    → Pipelined playback (synthesize N+1 while N plays)
```

The app never sits silent. Pre-written banter fills every gap. Voice-cached to disk — after first play, everything is instant.

---

## Zero-Latency Voice Cloning

The key innovation. Voice cloning normally takes 2-30 seconds per phrase. We eliminated that:

1. **Clone once** — extract voice state from a 10s WAV sample, save as `.safetensors` (~30s, one-time)
2. **Load instantly** — cached voice state loads in <100ms on every subsequent run
3. **Cache forever** — every synthesized phrase is saved to disk as WAV. Same phrase = 0ms next time
4. **Pipeline** — synthesize line N+1 while line N plays. No gaps between dialogue lines

After a few sessions, 90%+ of audio is pure disk reads. No compute. No latency.

> This caching architecture is extracted as a standalone library: [InstaClone](https://github.com/sameeeeeeep/instaclone)

---

## Project-Aware Commentary with `theater.md`

Drop a `.claude/theater.md` in your project and the app generates dialogue that knows your codebase:

```bash
# In any project, run:
/create-theater
```

This generates a theme-specific config with:
- **Project context** — what the project does, tech stack, key concepts
- **Custom few-shot examples** — dialogue reacting to events that would actually happen in YOUR project
- **Project-specific fillers** — banter about your actual tools, frameworks, and pain points
- **Term explainers** — explains project-specific terms in character when detected

The app uses **keyword-matched RAG** to pick the most relevant example for each event batch. The 3B model doesn't need to figure out your project — theater.md tells it.

---

## Character Themes

| Theme | Show | You play as | Vibe |
|-------|------|-------------|------|
| **Gilfoyle & Dinesh** | Silicon Valley | Richard | Dry roasts, Big Head stories, Erlich callbacks |
| **David & Moira** | Schitt's Creek | Johnny | Dramatic overreactions, elevated vocabulary, bébé |
| **Rick & Morty** | Rick and Morty | Jerry | Interdimensional incidents, *burp*, existential debugging |
| **Sherlock & Watson** | Sherlock | Lestrade | Deductive reasoning, Watson translates to plain English |
| **Chandler & Joey** | Friends | Ross | "Could this BE any more...", food references |
| **Dwight & Jim** | The Office | Michael | Beet farm incidents, "FALSE.", looks at camera |
| **Jesse & Walter** | Breaking Bad | Hank | "Yeah science!", purity obsession, no half measures |
| **Tony & JARVIS** | Iron Man | Pepper | Stark quips, probability calculations, 3 AM builds |
| **Professor & Bug** | Original | The Student | Teaching mode — explains concepts for beginners |

You always appear in the widget as "You (CharacterName)". Each theme has full personality profiles, speech style rules, catchphrases, and incident-style few-shot examples. Characters tell stories ("remember when Big Head..."), not analogies ("it's like...").

---

## Quick Start

### Prerequisites
- macOS 14+ (Apple Silicon)
- [Ollama](https://ollama.com) with Qwen 2.5: `ollama pull qwen2.5:3b`
- Python 3.10+ (for voice cloning sidecar)

### Build & Run
```bash
git clone https://github.com/sameeeeeeep/SiliconValleyTheater.git
cd SiliconValleyTheater
make build
open build/SiliconValleyTheater.app
```

### Voice Cloning Setup
```bash
cd TTSSidecar
python3 -m venv .venv && source .venv/bin/activate
pip install pocket-tts
```

Drop 10-15s WAV clips into `Resources/Voices/<theme>/` (e.g., `David.wav`, `Moira.wav`). The app clones voices on first startup and caches them as `.safetensors` for instant loading thereafter.

### Optional: Groq (faster, free)
Get a free API key at [console.groq.com](https://console.groq.com). Set it in Settings. Uses Llama 3.3 70B — much better dialogue quality than local 3B.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│               Claude Code Session (JSONL)                │
└────────────────────────┬────────────────────────────────┘
                         │ kqueue (DispatchSource, <1ms)
                ┌────────▼────────┐
                │  SessionWatcher │  tails latest JSONL file
                └────────┬────────┘
                         │ AsyncStream<SessionEvent>
                ┌────────▼────────┐
                │ EventSummarizer │  filters noise, keeps conversation
                │   (no LLM)     │  USER asks → CLAUDE responds → CHANGED files
                └────────┬────────┘
                         │ buffered 30s
           ┌─────────────▼─────────────┐
           │      TheaterEngine        │
           │  ┌─────────────────────┐  │
           │  │  theater.md (RAG)   │  │  keyword-matched project context
           │  │  + few-shot example │  │  injected into every prompt
           │  └─────────┬───────────┘  │
           │  ┌─────────▼───────────┐  │
           │  │   LLM Generation    │  │  Qwen 3B (local) / Llama 70B (Groq)
           │  │   6 dialogue lines  │  │  incident-style, in character
           │  └─────────┬───────────┘  │
           │  ┌─────────▼───────────┐  │
           │  │  Voice Synthesis    │  │  3-tier cache: phrase → disk → live
           │  │  (Pocket TTS)       │  │  pipelined: N+1 while N plays
           │  └─────────┬───────────┘  │
           │  ┌─────────▼───────────┐  │
           │  │  Gap Filling        │  │  DynamicFillerPool: consume & replenish
           │  │  (never silent)     │  │  context-matched by event tags
           │  └─────────────────────┘  │
           └───────────────────────────┘
                         │
                ┌────────▼────────┐
                │  Zoom Widget    │  floating panel, always-on-top
                │  + Subtitles    │  speaker highlighting, sound bars
                └─────────────────┘
```

### Why It's Never Silent

| Phase | What Plays | Latency |
|-------|-----------|---------|
| App starts | Cold open intro (10 variations, consumed once each) | 0ms (voice cached) |
| LLM warming up | Context discussion about your project | 0ms (cached) |
| Events buffering | Filler banter (context-matched, from pool) | 0ms (cached) |
| Events ready | LLM-generated dialogue (6 lines) | ~2-4s first line, 0ms pipelined |
| Between batches | Term explainers or more fillers | 0ms (cached) |
| Idle | LLM generates new fillers in background | pre-cached for next gap |

---

## Configuration

From the menu bar icon:

- **LLM**: Ollama (local) or Groq (cloud, free, faster)
- **TTS**: Pocket TTS (local cloning), Kokoro (fast), Fish Audio (cloud), Cartesia (cloud)
- **Theme**: 9 character themes, assignable per room
- **Buffer**: How long to collect events before generating (5-120s)
- **Volume**: Master volume + per-session control

---

## Project Structure

```
Sources/
├── Engine/
│   ├── TheaterEngine.swift          # Central orchestrator
│   └── DynamicFillerPool.swift      # Consume-and-replenish banter pool
├── Models/
│   ├── TheaterContext.swift         # theater.md parser + RAG
│   ├── CharacterTheme.swift         # 9 themes with personalities + examples
│   ├── FillerLibrary.swift          # Pre-written fillers + term explainers
│   ├── Config.swift                 # Settings, per-session theme map
│   ├── DialogueLine.swift           # Data models + dialogue parser
│   └── SessionEvent.swift           # JSONL event parser
├── Services/
│   ├── DialogueGenerator.swift      # Event summarizer + LLM prompt builder
│   ├── SessionWatcher.swift         # kqueue file watcher for JSONL
│   ├── OllamaClient.swift           # Local LLM client
│   ├── GroqClient.swift             # Cloud LLM client
│   ├── TTSManager.swift             # Pocket TTS sidecar manager
│   ├── FishAudioTTSManager.swift    # Fish Audio voice cloning
│   ├── CloudTTSManager.swift        # Cartesia cloud TTS
│   └── AudioPlayer.swift            # Pipelined audio playback
├── Views/
│   ├── WidgetView.swift             # Zoom-style floating widget
│   ├── VideoCallView.swift          # Character tiles + user tile
│   ├── ContentView.swift            # Full window with transcript
│   ├── CharacterPanelView.swift     # Character tile with sound bars
│   ├── SubtitleOverlay.swift        # Floating dialogue captions
│   ├── TranscriptView.swift         # Scrollable history
│   └── SettingsView.swift           # Configuration UI
└── SiliconValleyApp.swift           # Menu bar app entry point

TTSSidecar/                          # Python voice cloning sidecar
Resources/Voices/                    # WAV samples per theme
```

---

## License

MIT

---

*Built with Swift, MLX, Ollama, and the belief that coding should be more entertaining.*
