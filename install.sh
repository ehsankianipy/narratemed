#!/bin/bash
# ─────────────────────────────────────────────────────────────
# NarrateRad installer — Apple Silicon Mac
# Run with: curl -fsSL https://raw.githubusercontent.com/ehsankianipy/narraterad/main/install.sh | bash
# ─────────────────────────────────────────────────────────────

set -e

REPO="https://github.com/ehsankianipy/narraterad.git"
INSTALL_DIR="$HOME/narraterad"
BOLD=$(tput bold 2>/dev/null || echo "")
RESET=$(tput sgr0 2>/dev/null || echo "")
GREEN="\033[0;32m"
RED="\033[0;31m"
NC="\033[0m"

echo ""
echo "${BOLD}NarrateRad — Installer${RESET}"
echo "────────────────────────────────────────"
echo ""

# ── Check Apple Silicon ────────────────────────────────────────
if [ "$(uname -m)" != "arm64" ]; then
  echo -e "${RED}Error: NarrateRad requires an Apple Silicon Mac (M1/M2/M3/M4).${NC}"
  echo "Intel Mac support is coming in a future release."
  exit 1
fi
echo -e "${GREEN}✓${NC} Apple Silicon detected"

# ── Check macOS ────────────────────────────────────────────────
MACOS_VERSION=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MACOS_VERSION" -lt 13 ]; then
  echo -e "${RED}Error: macOS 13 (Ventura) or later is required.${NC}"
  exit 1
fi
echo -e "${GREEN}✓${NC} macOS $(sw_vers -productVersion)"

# ── Homebrew ───────────────────────────────────────────────────
echo ""
echo "Checking Homebrew..."
if ! command -v brew &>/dev/null; then
  echo "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
else
  echo -e "${GREEN}✓${NC} Homebrew already installed"
fi

# ── Ollama ─────────────────────────────────────────────────────
echo ""
echo "Checking Ollama..."
if ! command -v ollama &>/dev/null; then
  echo "Installing Ollama..."
  brew install ollama
else
  echo -e "${GREEN}✓${NC} Ollama already installed"
fi

echo "Starting Ollama service..."
brew services start ollama
sleep 3

echo "Downloading Llama 3.1 (4.7GB — this may take several minutes)..."
ollama pull llama3.1
echo -e "${GREEN}✓${NC} Llama 3.1 ready"

# ── uv ────────────────────────────────────────────────────────
echo ""
echo "Checking uv..."
if ! command -v uv &>/dev/null; then
  echo "Installing uv..."
  brew install uv
else
  echo -e "${GREEN}✓${NC} uv already installed"
fi

# ── Clone repo ────────────────────────────────────────────────
echo ""
echo "Downloading NarrateRad..."
if [ -d "$INSTALL_DIR" ]; then
  echo "Updating existing installation..."
  cd "$INSTALL_DIR" && git pull
else
  git clone "$REPO" "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"
echo -e "${GREEN}✓${NC} NarrateRad downloaded"

# ── Python environment ────────────────────────────────────────
echo ""
echo "Setting up Python 3.11 environment..."
uv python install 3.11
uv python pin 3.11
uv venv --python 3.11
uv add faster-whisper sounddevice numpy fastapi uvicorn httpx python-multipart websockets 2>/dev/null || true
uv add mlx-whisper sounddevice numpy fastapi uvicorn httpx python-multipart websockets
echo -e "${GREEN}✓${NC} Python environment ready"

# ── Download Whisper model ────────────────────────────────────
echo ""
echo "Downloading Whisper large-v3 model (1.4GB — this may take a few minutes)..."
uv run python -c "
import mlx_whisper, numpy as np
audio = np.zeros(16000, dtype='float32')
mlx_whisper.transcribe(audio, path_or_hf_repo='mlx-community/whisper-large-v3-mlx')
print('Whisper model ready')
"
echo -e "${GREEN}✓${NC} Whisper model downloaded"

# ── Create start script ───────────────────────────────────────
cat > "$INSTALL_DIR/start.sh" << 'STARTSCRIPT'
#!/bin/bash
cd "$(dirname "$0")"
echo "Starting NarrateRad..."
brew services start ollama 2>/dev/null || true
sleep 1
uv run uvicorn main:app --port 8000 &
SERVER_PID=$!
sleep 2
open http://localhost:8000
echo "NarrateRad running at http://localhost:8000"
echo "Press Ctrl+C to stop."
wait $SERVER_PID
STARTSCRIPT
chmod +x "$INSTALL_DIR/start.sh"

# ── Done ──────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────"
echo -e "${GREEN}${BOLD}NarrateRad installed successfully!${RESET}"
echo ""
echo "To start NarrateRad, run:"
echo "  ~/narraterad/start.sh"
echo ""
echo "Or add this alias to your shell:"
echo "  echo 'alias narraterad=\"~/narraterad/start.sh\"' >> ~/.zshrc"
echo "  source ~/.zshrc"
echo "  narraterad"
echo "────────────────────────────────────────"
echo ""
