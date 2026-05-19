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
YELLOW="\033[0;33m"
NC="\033[0m"

echo ""
echo "${BOLD}NarrateRad — Installer${RESET}"
echo "────────────────────────────────────────"
echo ""

# ── Check Apple Silicon ────────────────────────────────────────
if [ "$(uname -m)" != "arm64" ]; then
  echo -e "${RED}Error: This installer is for Apple Silicon Macs (M1/M2/M3/M4).${NC}"
  echo "For Windows, run install.ps1 instead."
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
uv add anthropic groq mlx-whisper sounddevice numpy fastapi uvicorn httpx python-multipart websockets
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

# ── API Key ───────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────"
echo "${BOLD}API Key Setup${RESET}"
echo ""
echo "NarrateRad uses the Claude API to structure radiology reports."
echo -e "Get your free key at: ${YELLOW}https://console.anthropic.com${NC}"
echo ""

if [ -f "$INSTALL_DIR/.env" ] && grep -q "ANTHROPIC_API_KEY" "$INSTALL_DIR/.env"; then
  echo -e "${GREEN}✓${NC} ANTHROPIC_API_KEY already set in .env"
else
  read -rp "Enter your Anthropic API key (sk-ant-...): " ANTHROPIC_KEY
  if [ -z "$ANTHROPIC_KEY" ]; then
    echo -e "${YELLOW}Warning: No key entered. Add it later to ~/narraterad/.env${NC}"
    echo "ANTHROPIC_API_KEY=" > "$INSTALL_DIR/.env"
  else
    echo "ANTHROPIC_API_KEY=$ANTHROPIC_KEY" > "$INSTALL_DIR/.env"
    echo -e "${GREEN}✓${NC} API key saved to .env"
  fi
fi

# ── Create start script ───────────────────────────────────────
cat > "$INSTALL_DIR/start.sh" << 'STARTSCRIPT'
#!/bin/bash
cd "$(dirname "$0")"
echo "Starting NarrateRad..."
uv run uvicorn main:app --port 8000 --ws-ping-interval 20 --ws-ping-timeout 60 &
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
