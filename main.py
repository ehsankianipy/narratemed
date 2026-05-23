"""
main.py — NarrateRad
====================
Local FastAPI web server.

Endpoints:
  GET  /          — serves the frontend UI
  WS   /ws        — real-time audio → transcription pipeline
  POST /structure — structures transcript into MT-ready preliminary report

Run with:
  uv run uvicorn main:app --reload --port 8000
"""

import asyncio
import json
import os
import re
import shutil
import subprocess
import tomllib
import traceback
from pathlib import Path

import httpx
import numpy as np
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse

from nlp import check_all
from radlex import standardise
from structure import ClaudeNotConfiguredError, PatientInfo, structure_report_stream
from transcribe import Transcriber


def _load_dotenv() -> None:
    env_path = Path(__file__).parent / ".env"
    if not env_path.exists():
        return
    with env_path.open() as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip("\"'")
            if key:
                os.environ.setdefault(key, value)


_load_dotenv()

# ── Config ────────────────────────────────────────────────────────────────────

SAMPLE_RATE: int = 16_000
TRANSCRIPTION_INTERVAL: int = 10
OVERLAP_SECONDS: int = 2
FRONTEND_PATH = Path(__file__).parent / "frontend" / "index.html"

# ── App ───────────────────────────────────────────────────────────────────────

app = FastAPI(title="NarrateMed")
transcriber = Transcriber()


# ── Routes ────────────────────────────────────────────────────────────────────


@app.get("/")
async def index() -> HTMLResponse:
    if not FRONTEND_PATH.exists():
        return HTMLResponse("<h2>Frontend not found.</h2>")
    return HTMLResponse(FRONTEND_PATH.read_text(encoding="utf-8"))


@app.post("/structure")
async def structure(payload: dict) -> dict:
    text = payload.get("text", "").strip()
    if not text:
        return {"error": "No text provided"}

    patient = PatientInfo(
        name=payload.get("patient_name", ""),
        age=payload.get("patient_age", ""),
        mr_number=payload.get("mr_number", ""),
        referring_physician=payload.get("referring_physician", ""),
    )
    specialty = payload.get("specialty", "radiology")

    try:
        report = ""
        async for chunk in structure_report_stream(text, patient, specialty):
            report += chunk
        return {"structured": report}
    except ClaudeNotConfiguredError as e:
        return {"error": str(e)}
    except Exception as e:
        return {"error": str(e)}


@app.get("/check-update")
async def check_update() -> dict:
    pyproject = Path(__file__).parent / "pyproject.toml"
    with open(pyproject, "rb") as f:
        local = tomllib.load(f)["project"]["version"]
    try:
        async with httpx.AsyncClient(timeout=8.0) as client:
            r = await client.get(
                "https://raw.githubusercontent.com/ehsankianipy/narratemed/main/pyproject.toml"
            )
            m = re.search(r'version\s*=\s*"([^"]+)"', r.text)
            remote = m.group(1) if m else local
    except Exception:
        return {"local": local, "remote": local, "update_available": False}

    def ver(v: str) -> tuple:
        return tuple(int(x) for x in v.split("."))

    return {"local": local, "remote": remote, "update_available": ver(remote) > ver(local)}


@app.post("/update")
async def do_update() -> dict:
    install_dir = Path(__file__).parent
    uv = shutil.which("uv") or "uv"

    def run() -> str:
        r1 = subprocess.run(
            ["git", "pull", "origin", "main"],
            cwd=install_dir, capture_output=True, text=True, timeout=60,
        )
        if r1.returncode != 0:
            raise RuntimeError(f"git pull failed: {r1.stderr.strip()}")
        r2 = subprocess.run(
            [uv, "sync"],
            cwd=install_dir, capture_output=True, text=True, timeout=120,
        )
        if r2.returncode != 0:
            raise RuntimeError(f"uv sync failed: {r2.stderr.strip()}")
        return "ok"

    try:
        await asyncio.get_event_loop().run_in_executor(None, run)
        return {"success": True}
    except Exception as e:
        return {"error": str(e)}


@app.websocket("/ws")
async def websocket_transcribe(ws: WebSocket) -> None:
    await ws.accept()

    # Heartbeat — keeps connection alive during long Whisper transcriptions
    async def heartbeat() -> None:
        while True:
            await asyncio.sleep(5)
            await _send(ws, {"type": "ping"})

    heartbeat_task = asyncio.create_task(heartbeat())

    buf: np.ndarray = np.zeros(0, dtype=np.float32)
    interval_samples = SAMPLE_RATE * TRANSCRIPTION_INTERVAL
    overlap_samples = SAMPLE_RATE * OVERLAP_SECONDS
    transcribing = False

    await _send(ws, {"type": "status", "message": "Connected — start speaking"})

    try:
        while True:
            raw = await ws.receive_bytes()
            incoming = np.frombuffer(raw, dtype=np.float32).copy()
            buf = np.concatenate([buf, incoming])

            if len(buf) >= interval_samples and not transcribing:
                audio_chunk = buf[:interval_samples].copy()
                buf = buf[interval_samples - overlap_samples:]

                transcribing = True
                await _send(ws, {"type": "status", "message": "Transcribing..."})

                loop = asyncio.get_event_loop()
                try:
                    result = await loop.run_in_executor(
                        None, transcriber.transcribe, audio_chunk
                    )
                except Exception as exc:
                    transcribing = False
                    await _send(ws, {"type": "status", "message": f"Transcription error: {exc}"})
                    await _send(ws, {"type": "status", "message": "Listening..."})
                    continue
                transcribing = False

                if not result.is_empty():

                    # ── Transcript update ──────────────────────────────────
                    await _send(ws, {
                        "type": "transcript_update",
                        "words": [
                            {
                                "text": w.text,
                                "start": w.start,
                                "end": w.end,
                                "probability": w.probability,
                                "flagged": w.flagged,
                            }
                            for w in result.words
                        ],
                        "full_text": result.text,
                        "flag_rate": round(result.flag_rate, 3),
                        "language": result.language,
                    })

                    # ── NLP checks ─────────────────────────────────────────
                    nlp_flags = check_all(result.text)
                    if nlp_flags:
                        await _send(ws, {
                            "type": "nlp_flags",
                            "flags": [f.to_dict() for f in nlp_flags],
                        })

                    # ── RadLex standardisation ─────────────────────────────
                    standardised_text, radlex_corrections = standardise(result.text)
                    if radlex_corrections:
                        await _send(ws, {
                            "type": "radlex_corrections",
                            "corrections": [
                                {
                                    "original": c.original,
                                    "standardised": c.standardised,
                                    "concept": c.radlex_concept,
                                }
                                for c in radlex_corrections
                            ],
                            "standardised_text": standardised_text,
                        })

                await _send(ws, {"type": "status", "message": "Listening..."})

    except WebSocketDisconnect:
        pass
    except Exception as e:
        traceback.print_exc()
        try:
            await _send(ws, {"type": "status", "message": f"Error: {str(e)}"})
        except Exception:
            pass
    finally:
        heartbeat_task.cancel()


# ── Helpers ───────────────────────────────────────────────────────────────────


async def _send(ws: WebSocket, payload: dict) -> None:
    try:
        await ws.send_text(json.dumps(payload))
    except Exception:
        pass
