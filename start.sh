#!/bin/bash
cd "$(dirname "$0")"
echo "Starting NarrateRad..."
brew services start ollama 2>/dev/null || true
sleep 1
uv run uvicorn main:app --port 8000 --ws-ping-interval 20 --ws-ping-timeout 60 &
SERVER_PID=$!
sleep 2
open http://localhost:8000
echo "NarrateRad running at http://localhost:8000"
echo "Press Ctrl+C to stop."
wait $SERVER_PID
