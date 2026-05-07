# NarrateRad

AI-powered voice-to-text radiology reporting. Runs entirely on your Mac — no data leaves your machine.

## Requirements

- Apple Silicon Mac (M1 / M2 / M3 / M4)
- macOS 13 (Ventura) or later
- ~8GB free disk space (for AI models)
- Internet connection for first-time setup

## Install

Open Terminal and run:

```bash
curl -fsSL https://raw.githubusercontent.com/ehsankianipy/narraterad/main/install.sh | bash
```

This takes 10–20 minutes on first run (downloads ~6GB of AI models). Subsequent launches are instant.

## Start

```bash
~/narraterad/start.sh
```

Then open **http://localhost:8000** in your browser.

## Usage

1. Click the green mic button and start dictating
2. Your transcript appears live — amber words are low-confidence
3. NLP flags appear on the left for laterality errors, contradictions, and critical findings
4. Click **Structure report** to generate a formatted radiology report
5. Copy the report from the right panel

## What runs locally

| Component | Model |
|---|---|
| Speech recognition | Whisper large-v3 (mlx-community) |
| Report structuring | Llama 3.1 8B via Ollama |

## Stop

Press `Ctrl+C` in the Terminal window running NarrateRad.
