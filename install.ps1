# NarrateRad Windows Installer
# ─────────────────────────────────────────────────────────────────────────────
# Run by double-clicking install.bat, or directly in PowerShell:
#   powershell -ExecutionPolicy Bypass -File install.ps1
# ─────────────────────────────────────────────────────────────────────────────

$ErrorActionPreference = "Stop"
$REPO = "https://github.com/ehsankianipy/narraterad.git"
$INSTALL_DIR = "$env:USERPROFILE\narraterad"

function Write-Step { param($msg) Write-Host "`n>> $msg" -ForegroundColor Cyan }
function Write-OK   { param($msg) Write-Host "   OK: $msg" -ForegroundColor Green }
function Write-Fail { param($msg) Write-Host "   ERROR: $msg" -ForegroundColor Red; Read-Host "Press Enter to exit"; exit 1 }

Clear-Host
Write-Host ""
Write-Host "  NarrateRad Installer for Windows" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

# ── Python 3.11 ───────────────────────────────────────────────────────────────
Write-Step "Checking Python 3.11..."
$python = $null
foreach ($cmd in @("python3.11", "python3", "python")) {
    try {
        $ver = & $cmd --version 2>&1
        if ($ver -match "3\.11") { $python = $cmd; break }
    } catch {}
}

if (-not $python) {
    Write-Host "   Python 3.11 not found." -ForegroundColor Yellow
    Write-Host "   Opening python.org — please download and install Python 3.11." -ForegroundColor Yellow
    Start-Process "https://www.python.org/downloads/release/python-3119/"
    Write-Host "   After installing Python, run this installer again." -ForegroundColor Yellow
    Read-Host "`n   Press Enter to exit"
    exit 0
}
Write-OK "Python found: $python"

# ── Git ───────────────────────────────────────────────────────────────────────
Write-Step "Checking Git..."
try {
    $gitVer = & git --version 2>&1
    Write-OK $gitVer
} catch {
    Write-Host "   Git not found. Opening git-scm.com..." -ForegroundColor Yellow
    Start-Process "https://git-scm.com/download/win"
    Write-Host "   After installing Git, run this installer again." -ForegroundColor Yellow
    Read-Host "`n   Press Enter to exit"
    exit 0
}

# ── Ollama ────────────────────────────────────────────────────────────────────
Write-Step "Checking Ollama..."
try {
    $ollamaVer = & ollama --version 2>&1
    Write-OK "Ollama already installed"
} catch {
    Write-Host "   Ollama not found. Downloading installer..." -ForegroundColor Yellow
    $ollamaInstaller = "$env:TEMP\OllamaSetup.exe"
    Invoke-WebRequest -Uri "https://ollama.com/download/OllamaSetup.exe" -OutFile $ollamaInstaller
    Write-Host "   Installing Ollama..." -ForegroundColor Yellow
    Start-Process -FilePath $ollamaInstaller -ArgumentList "/S" -Wait
    Write-OK "Ollama installed"
}

Write-Step "Starting Ollama service..."
Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
Start-Sleep -Seconds 3
Write-OK "Ollama running"

Write-Step "Downloading Llama 3.1 (4.7GB - this will take several minutes)..."
Write-Host "   Please wait — do not close this window..." -ForegroundColor Yellow
& ollama pull llama3.1
Write-OK "Llama 3.1 ready"

# ── uv ────────────────────────────────────────────────────────────────────────
Write-Step "Checking uv..."
try {
    $uvVer = & uv --version 2>&1
    Write-OK $uvVer
} catch {
    Write-Host "   Installing uv..." -ForegroundColor Yellow
    Invoke-RestMethod "https://astral.sh/uv/install.ps1" | Invoke-Expression
    $env:PATH = "$env:USERPROFILE\.local\bin;$env:PATH"
    Write-OK "uv installed"
}

# ── Clone repo ────────────────────────────────────────────────────────────────
Write-Step "Downloading NarrateRad..."
if (Test-Path $INSTALL_DIR) {
    Write-Host "   Updating existing installation..." -ForegroundColor Yellow
    Set-Location $INSTALL_DIR
    & git pull
} else {
    & git clone $REPO $INSTALL_DIR
    Set-Location $INSTALL_DIR
}
Write-OK "NarrateRad downloaded to $INSTALL_DIR"

# ── Python environment ────────────────────────────────────────────────────────
Write-Step "Setting up Python environment..."
& uv python install 3.11
& uv python pin 3.11
& uv venv --python 3.11
& uv add faster-whisper sounddevice numpy fastapi uvicorn httpx python-multipart websockets
Write-OK "Python environment ready"

# ── Download Whisper model ────────────────────────────────────────────────────
Write-Step "Downloading Whisper medium model (this may take a few minutes)..."
Write-Host "   Please wait..." -ForegroundColor Yellow
& uv run python -c @"
from faster_whisper import WhisperModel
print('Downloading Whisper medium model...')
model = WhisperModel('medium', device='cpu', compute_type='int8')
print('Whisper model ready')
"@
Write-OK "Whisper model downloaded"

# ── Create start script ───────────────────────────────────────────────────────
Write-Step "Creating launcher..."
$startScript = @"
@echo off
cd /d "%~dp0"
echo Starting NarrateRad...
start "" /B ollama serve
timeout /t 2 /nobreak >nul
start /B uv run uvicorn main:app --port 8000 --ws-ping-interval 20 --ws-ping-timeout 60
timeout /t 3 /nobreak >nul
start http://localhost:8000
echo.
echo NarrateRad is running at http://localhost:8000
echo Open Chrome or Edge and go to http://localhost:8000
echo.
echo Press any key to stop NarrateRad...
pause >nul
taskkill /F /IM uvicorn.exe >nul 2>&1
taskkill /F /IM ollama.exe >nul 2>&1
echo NarrateRad stopped.
"@
$startScript | Out-File -FilePath "$INSTALL_DIR\start.bat" -Encoding ASCII

Write-OK "Launcher created at $INSTALL_DIR\start.bat"

# ── Desktop shortcut ──────────────────────────────────────────────────────────
Write-Step "Creating desktop shortcut..."
$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut("$env:USERPROFILE\Desktop\NarrateRad.lnk")
$Shortcut.TargetPath = "$INSTALL_DIR\start.bat"
$Shortcut.WorkingDirectory = $INSTALL_DIR
$Shortcut.Description = "NarrateRad — Radiology Voice Dictation"
$Shortcut.Save()
Write-OK "Desktop shortcut created"

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  NarrateRad installed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "  To start NarrateRad:" -ForegroundColor White
Write-Host "  Double-click NarrateRad on your Desktop" -ForegroundColor White
Write-Host "  Or run: $INSTALL_DIR\start.bat" -ForegroundColor Gray
Write-Host ""
Write-Host "  Open Chrome or Edge — NOT Internet Explorer" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
Read-Host "  Press Enter to exit"
