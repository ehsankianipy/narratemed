# NarrateMed Windows Installer
# -----------------------------------------------------------------------------
# Run by double-clicking install.bat, or directly in PowerShell:
#   powershell -ExecutionPolicy Bypass -File install.ps1
# -----------------------------------------------------------------------------

$ErrorActionPreference = "Stop"
$REPO = "https://github.com/ehsankianipy/narratemed.git"
$INSTALL_DIR = "$env:USERPROFILE\narratemed"

function Write-Step { param($msg) Write-Host "`n>> $msg" -ForegroundColor Cyan }
function Write-OK   { param($msg) Write-Host "   OK: $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "   WARNING: $msg" -ForegroundColor Yellow }
function Write-Fail { param($msg) Write-Host "   ERROR: $msg" -ForegroundColor Red; Read-Host "Press Enter to exit"; exit 1 }

Clear-Host
Write-Host ""
Write-Host "  NarrateMed Installer for Windows" -ForegroundColor White
Write-Host "  ------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

# -- Python 3.11 --------------------------------------------------------------
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
    Write-Host "   Opening python.org - please download and install Python 3.11." -ForegroundColor Yellow
    Start-Process "https://www.python.org/downloads/release/python-3119/"
    Write-Host "   After installing Python, run this installer again." -ForegroundColor Yellow
    Read-Host "`n   Press Enter to exit"
    exit 0
}
Write-OK "Python found: $python"

# -- Git ----------------------------------------------------------------------
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

# -- uv -----------------------------------------------------------------------
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

# -- Clone repo ---------------------------------------------------------------
Write-Step "Downloading NarrateMed..."
if (Test-Path $INSTALL_DIR) {
    Write-Host "   Updating existing installation..." -ForegroundColor Yellow
    Set-Location $INSTALL_DIR
    & git pull
} else {
    & git clone $REPO $INSTALL_DIR
    Set-Location $INSTALL_DIR
}
Write-OK "NarrateMed downloaded to $INSTALL_DIR"

# -- Python environment -------------------------------------------------------
Write-Step "Setting up Python environment..."
& uv python install 3.11
& uv python pin 3.11
& uv venv --python 3.11
& uv add anthropic groq sounddevice numpy fastapi uvicorn httpx python-multipart websockets
Write-OK "Python environment ready"

# -- API Keys -----------------------------------------------------------------
Write-Step "API Key Setup"
Write-Host ""
Write-Host "   NarrateMed needs two free API keys:" -ForegroundColor White
Write-Host "   1. Claude (for report structuring) - https://console.anthropic.com" -ForegroundColor Gray
Write-Host "   2. Groq   (for voice transcription) - https://console.groq.com" -ForegroundColor Gray
Write-Host ""

$envFile = "$INSTALL_DIR\.env"

# Check for existing keys
$existingAnthropic = ""
$existingGroq = ""
if (Test-Path $envFile) {
    $lines = Get-Content $envFile
    foreach ($line in $lines) {
        if ($line -match "^ANTHROPIC_API_KEY=(.+)") { $existingAnthropic = $Matches[1] }
        if ($line -match "^GROQ_API_KEY=(.+)")      { $existingGroq      = $Matches[1] }
    }
}

if ($existingAnthropic) {
    Write-OK "ANTHROPIC_API_KEY already set"
    $anthropicKey = $existingAnthropic
} else {
    $anthropicKey = Read-Host "   Enter your Anthropic API key (sk-ant-...)"
    if (-not $anthropicKey) {
        Write-Warn "No Anthropic key entered - add it later to $envFile"
        $anthropicKey = ""
    }
}

if ($existingGroq) {
    Write-OK "GROQ_API_KEY already set"
    $groqKey = $existingGroq
} else {
    $groqKey = Read-Host "   Enter your Groq API key (gsk_...)"
    if (-not $groqKey) {
        Write-Warn "No Groq key entered - add it later to $envFile"
        $groqKey = ""
    }
}

"ANTHROPIC_API_KEY=$anthropicKey`nGROQ_API_KEY=$groqKey" | Out-File -FilePath $envFile -Encoding ASCII
Write-OK "API keys saved to .env"

# -- Create start script ------------------------------------------------------
Write-Step "Creating launcher..."
$startScript = @"
@echo off
cd /d "%~dp0"
echo Starting NarrateMed...
start /B uv run uvicorn main:app --port 8000 --ws-ping-interval 10 --ws-ping-timeout 30
timeout /t 3 /nobreak >nul
start http://localhost:8000
echo.
echo NarrateMed is running at http://localhost:8000
echo Open Chrome or Edge and go to http://localhost:8000
echo.
echo Press any key to stop NarrateMed...
pause >nul
taskkill /F /IM uvicorn.exe >nul 2>&1
echo NarrateMed stopped.
"@
$startScript | Out-File -FilePath "$INSTALL_DIR\start.bat" -Encoding ASCII
Write-OK "Launcher created at $INSTALL_DIR\start.bat"

# -- Desktop shortcut ---------------------------------------------------------
Write-Step "Creating desktop shortcut..."
$WshShell = New-Object -ComObject WScript.Shell
$desktopPath = [Environment]::GetFolderPath('Desktop')
$Shortcut = $WshShell.CreateShortcut("$desktopPath\NarrateMed.lnk")
$Shortcut.TargetPath = "$INSTALL_DIR\start.bat"
$Shortcut.WorkingDirectory = $INSTALL_DIR
$Shortcut.Description = "NarrateMed - Medical Voice Dictation"
$Shortcut.Save()
Write-OK "Desktop shortcut created"

# -- Done ---------------------------------------------------------------------
Write-Host ""
Write-Host "  ------------------------------------------" -ForegroundColor DarkGray
Write-Host "  NarrateMed installed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "  To start NarrateMed:" -ForegroundColor White
Write-Host "  Double-click NarrateMed on your Desktop" -ForegroundColor White
Write-Host "  Or run: $INSTALL_DIR\start.bat" -ForegroundColor Gray
Write-Host ""
Write-Host "  Open Chrome or Edge - NOT Internet Explorer" -ForegroundColor Yellow
Write-Host "  ------------------------------------------" -ForegroundColor DarkGray
Write-Host ""
Read-Host "  Press Enter to exit"
