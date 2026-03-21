# SiliconValley Theater

**AI characters commentate your Claude Code sessions live -- like a director's commentary for coding.**

Imagine Gilfoyle roasting your variable names while Dinesh nervously defends your architecture choices. Or Walter White narrating a critical refactor like it's a drug empire. SiliconValley Theater watches your Claude Code sessions in real time and generates fully-voiced, in-character dialogue about what's happening in your code.

Everything runs locally. Your code never leaves your machine.

---

## Features

- **Live Commentary** -- Characters react to your Claude Code session events in real time
- **Local Voice Cloning** -- Clone any voice with a 10-second audio sample using Pocket TTS
- **Local LLM Support** -- Run entirely offline with Ollama, or use Groq for speed
- **Multiple Character Themes** -- Silicon Valley, Rick & Morty, Breaking Bad, The Office, and more
- **Session Picker** -- Monitor multiple Claude Code sessions and switch between them
- **Floating Widget** -- A compact, always-on-top overlay that stays out of your way
- **Menu Bar App** -- Lives in your macOS menu bar, launches instantly
- **Voice Lab** -- Web-based UI for cloning, previewing, and managing character voices
- **Subtitle Overlay** -- See what characters are saying as captions on screen

## How It Works

```
Claude Code JSONL
       |
  Event Watcher        watches ~/.claude/projects/ for session activity
       |
  Summarizer           distills raw events into concise coding context
       |
  LLM (Ollama/Groq)   generates in-character dialogue from the summary
       |
  Dialogue Engine      manages character turns, timing, and personality
       |
  TTS (Pocket/Kokoro)  synthesizes speech with cloned character voices
       |
  Audio Player         plays dialogue with subtitle overlay
```

## Quick Start

### Prerequisites

- macOS 14+
- [Ollama](https://ollama.com) installed (or a Groq API key)
- Python 3.10+ (for the TTS sidecar)

### 1. Clone and build

```bash
git clone https://github.com/sameeprehlan/SiliconValleyTheater.git
cd SiliconValleyTheater

# Build the Swift app
swift build

# Set up the TTS sidecar
cd TTSSidecar
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### 2. Pull an Ollama model

```bash
ollama pull llama3.2
```

### 3. Run

```bash
# Start the TTS server
cd TTSSidecar && source .venv/bin/activate && python server.py

# In another terminal, run the app
swift run
```

The app appears in your menu bar. Select a Claude Code session and pick a character theme -- commentary begins automatically.

## Voice Lab

The built-in Voice Lab lets you clone and manage character voices through a web interface.

```bash
cd TTSSidecar
python voicelab.py
# Opens at http://localhost:5555
```

From there you can:

- Record or upload a voice sample
- Clone it to a character slot using Pocket TTS
- Preview and compare voice outputs
- Generate phrase caches for faster playback

## Screenshots

> Coming soon -- screenshots of the floating widget, character panel, and Voice Lab UI.

## Tech Stack

| Layer | Technology |
|-------|-----------|
| App | Swift, SwiftUI, AppKit |
| LLM | Ollama (local), Groq (cloud) |
| TTS | Pocket TTS, Kokoro, macOS native |
| Voice Cloning | Pocket TTS (local, 10s samples) |
| Sidecar | Python, FastAPI |

## Character Themes

Each theme includes 2+ characters with distinct personalities and speech patterns:

| Theme | Characters |
|-------|-----------|
| Silicon Valley | Gilfoyle, Dinesh, Richard, Jared |
| Breaking Bad | Walter White, Jesse Pinkman |
| The Office | Michael Scott, Dwight Schrute |
| Rick and Morty | Rick, Morty |

Want to add your own? Define a new `CharacterTheme` in `Sources/Models/CharacterTheme.swift`.

## Project Structure

```
Sources/
  Engine/          TheaterEngine -- orchestrates the whole show
  Models/          CharacterTheme, DialogueLine, SessionEvent, Config
  Services/        SessionWatcher, DialogueGenerator, TTS, Audio, LLM clients
  Views/           SwiftUI views -- widget, settings, transcript, overlays
TTSSidecar/        Python TTS server with voice cloning and Voice Lab
Resources/         Voice assets and bundled resources
```

## License

MIT

---

Built for developers who think coding deserves better background dialogue.
