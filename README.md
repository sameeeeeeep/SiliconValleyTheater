# 🎬 SiliconValley Theater

### What do you do when Claude Code codes?

You watch. But watching a terminal scroll is boring. What if your coding session had a **live director's commentary** — voiced by your favorite TV characters?

SiliconValley Theater turns your Claude Code sessions into a **live comedy show**. Gilfoyle roasts your variable names while Dinesh nervously defends your architecture. Walter White narrates your refactor like it's a cook. Rick burps through your deployment.

**100% local. Your code never leaves your machine.**

---

## ✨ What Makes It Special

🎭 **9 Character Themes** — Silicon Valley, Rick & Morty, Breaking Bad, The Office, Friends, Sherlock, Iron Man, Schitt's Creek, and a Professor/Student duo for learning

🎤 **Local Voice Cloning** — Clone any voice from a 10-second sample using [Pocket TTS](https://github.com/kyutai-labs/pocket-tts). Runs on-device via Apple MLX

🧠 **Smart Event Understanding** — Doesn't just read file names. Explains *what happened and why it matters* using everyday analogies

🎓 **Technical Explainers** — Detects terms like "cache", "API", "JWT" in your session and plays fun explainer segments ("Caching is like keeping pizza in the fridge instead of calling the pizza place every night")

📺 **Zoom-Style Widget** — Floating video call layout with two character tiles, subtitles, speaker highlighting, and a Zoom-style control bar

🏠 **Multi-Room Sessions** — Monitor multiple Claude Code sessions simultaneously. Each "room" gets its own character theme. Switch between rooms like Zoom breakout rooms

🔄 **Zero-Gap Playback** — Pre-written filler banter plays during LLM generation gaps. Voice-cached to disk — after first play, fillers are instant (zero compute)

🎬 **Dynamic Intros** — Characters "join a call" at startup, discuss your project by name, react to your first message — all while the LLM warms up in the background

---

## 🏗 Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Claude Code Session                       │
│              (JSONL at ~/.claude/projects/)                  │
└──────────────────────┬──────────────────────────────────────┘
                       │
              ┌────────▼────────┐
              │  Event Watcher  │  watches session files in real time
              └────────┬────────┘
                       │
              ┌────────▼────────┐
              │  Summarizer     │  zero-latency string parsing
              │  (no LLM)      │  "Tool: Bash npm test" → "Ran the test suite"
              └────────┬────────┘
                       │
              ┌────────▼────────┐
              │  Dialogue Gen   │  Qwen 2.5 3B via Ollama (local)
              │  + few-shot     │  character-specific examples per theme
              └────────┬────────┘
                       │
              ┌────────▼────────┐
              │  Pocket TTS     │  local voice cloning on Apple Silicon
              │  (MLX)          │  clone any voice from 10s sample
              └────────┬────────┘
                       │
              ┌────────▼────────┐
              │  Audio Player   │  pipelined: synthesize N+1 while N plays
              │  + Voice Cache  │  disk-persisted WAV cache for fillers
              └─────────────────┘
```

### The Smart Playback Pipeline

The app never sits silent. Here's how:

1. **App starts** → Pre-written "joining the call" intro plays (voice-cached, instant)
2. **During intro** → LLM generates context discussion from your project name + first message
3. **Intro ends** → Context discussion plays seamlessly
4. **Real events buffer** → LLM generates commentary from 30s of accumulated events
5. **Between batches** → Term-triggered explainer fillers play (cached, instant)
6. **Idle periods** → Pre-written character banter fills gaps (cached, instant)

Result: continuous dialogue with zero silence, even on an 8GB M1.

---

## 🚀 Quick Start

### Prerequisites
- macOS 14+ (Apple Silicon)
- [Ollama](https://ollama.com) with Qwen 2.5 3B: `ollama pull qwen2.5:3b`
- Python 3.10+ (for TTS sidecar)

### Build & Run
```bash
git clone https://github.com/sameeeeeeep/SiliconValleyTheater.git
cd SiliconValleyTheater
make build
open build/SiliconValleyTheater.app
```

### Voice Cloning Setup
1. Install Pocket TTS: `cd TTSSidecar && python3 -m venv .venv && source .venv/bin/activate && pip install pocket-tts`
2. Accept terms at [HuggingFace](https://huggingface.co/kyutai/pocket-tts) and `huggingface-cli login`
3. Drop 10-15s WAV clips into `Resources/Voices/<theme>/` (e.g., `gilfoyle.wav`)
4. The app clones voices automatically on startup

---

## 🎭 Character Themes

| Theme | Characters | Show | Vibe |
|-------|-----------|------|------|
| **Gilfoyle & Dinesh** | Bertram Gilfoyle, Dinesh Chugtai | Silicon Valley | Dry roasts, Erlich stories, Big Head references |
| **Rick & Morty** | Rick Sanchez, Morty Smith | Rick and Morty | Interdimensional analogies, *burp*, existential debugging |
| **Jesse & Walter** | Jesse Pinkman, Walter White | Breaking Bad | "Yeah science!", purity obsession, no half measures |
| **Dwight & Jim** | Dwight Schrute, Jim Halpert | The Office | Beet farm analogies, looks at camera, "FALSE." |
| **Chandler & Joey** | Chandler Bing, Joey Tribbiani | Friends | "Could this BE any more...", food analogies |
| **Sherlock & Watson** | Sherlock Holmes, Dr. Watson | Sherlock | Deduction, "Elementary", Watson translates to plain English |
| **Tony & JARVIS** | Tony Stark, JARVIS | Iron Man | Stark quips, probability calculations, 3 AM builds |
| **David & Moira** | David Rose, Moira Rose | Schitt's Creek | Dramatic overreactions, elevated vocabulary, bébé |
| **Professor & Bug** | Professor Pixel, Bug | Original | Teaching mode — explains concepts for beginners |

---

## 🧠 Technical Explainer Fillers

When the app detects technical terms in your session, it plays contextual explainers:

| Term Detected | Analogy |
|--------------|---------|
| Cache | "Pizza in the fridge instead of calling every night" |
| API | "A restaurant menu — you order, the kitchen delivers" |
| Deploy | "Surgery on a patient who's still awake" |
| Tests | "Spell-check for code" |
| Refactor | "Reorganizing your closet" |
| Database | "A filing cabinet with superpowers" |
| Git | "A time machine for your code" |
| Auth/JWT | "A wristband at a concert" |
| Docker | "Shipping your code in a box with everything it needs" |
| Kubernetes | "An air traffic controller for your containers" |
| WebSocket | "A phone call — the line stays open both ways" |
| Regex | "Super-powered Find and Replace written by a cat" |
| CORS | "A nightclub with a very strict door policy" |
| Serverless | "Hiring a chef only when you have dinner guests" |
| TypeScript | "JavaScript but with a helmet on" |

---

## 📁 Project Structure

```
Sources/
├── Engine/
│   ├── TheaterEngine.swift          # Core orchestrator — events → dialogue → speech
│   └── DynamicFillerPool.swift      # Consume-and-replenish filler pool
├── Models/
│   ├── Config.swift                 # Settings, per-session theme map
│   ├── CharacterTheme.swift         # 9 themes with few-shot examples
│   ├── FillerLibrary.swift          # Pre-written fillers + term explainers
│   ├── DialogueLine.swift           # Data models + dialogue parser
│   └── SessionEvent.swift           # Claude Code JSONL event parser
├── Services/
│   ├── DialogueGenerator.swift      # Event summarizer + LLM prompt builder
│   ├── SessionWatcher.swift         # Watches Claude Code JSONL files
│   ├── OllamaClient.swift           # Local LLM via Ollama
│   ├── GroqClient.swift             # Cloud LLM via Groq
│   ├── TTSManager.swift             # Pocket TTS / Kokoro sidecar
│   ├── FishAudioTTSManager.swift    # Fish Audio cloud voice cloning
│   ├── CloudTTSManager.swift        # Cartesia cloud TTS
│   └── AudioPlayer.swift            # Pipelined audio playback
├── Views/
│   ├── WidgetView.swift             # Zoom-style floating widget with rooms
│   ├── VideoCallView.swift          # Full-size video call layout
│   ├── ContentView.swift            # Main panel with transcript
│   ├── CharacterPanelView.swift     # Character tile with speaking indicator
│   ├── SubtitleOverlay.swift        # Floating dialogue subtitle
│   ├── TranscriptView.swift         # Scrollable dialogue history
│   └── SettingsView.swift           # Configuration UI
└── SiliconValleyApp.swift           # Menu bar app entry point

TTSSidecar/                          # Python sidecar for local TTS
Resources/Voices/                    # Voice samples per theme
```

---

## 🔧 Configuration

Access settings from the menu bar icon. Key options:

- **LLM Provider**: Ollama (local) or Groq (cloud, faster)
- **TTS Engine**: Pocket TTS (local cloning), Kokoro (fast local), Fish Audio (cloud cloning), Cartesia (cloud)
- **Buffer Duration**: How long to collect events before generating (default: 30s)
- **Theme**: Pick from 9 character themes
- **Per-Room Themes**: Assign different themes to different sessions

---

## 📄 License

MIT

---

*Built with Swift, MLX, Ollama, and an unhealthy obsession with making coding less boring.*
