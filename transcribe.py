"""
transcribe.py — NarrateRad
==========================
Cross-platform Whisper transcription module.

Automatically selects the right backend:
  - Apple Silicon Mac  → mlx-whisper  (Metal GPU, fast, local)
  - Windows / Intel    → Groq Whisper API (whisper-large-v3, cloud, fast + accurate)

The rest of the app (main.py, nlp.py, structure.py) is identical on both
platforms — only this file differs in its backend.
"""

from __future__ import annotations

import io
import os
import platform
import re
import wave
from dataclasses import dataclass

import numpy as np
from radlex import RADLEX_PROMPT
RADIOLOGY_PROMPT = RADLEX_PROMPT

# ── Platform detection ────────────────────────────────────────────────────────

IS_APPLE_SILICON: bool = (
    platform.system() == "Darwin" and platform.machine() == "arm64"
)

# ── Constants ─────────────────────────────────────────────────────────────────

SAMPLE_RATE: int = 16_000
CONFIDENCE_THRESHOLD: float = 0.6
MIN_AUDIO_SECONDS: float = 1.0

# Apple Silicon model
MLX_MODEL_REPO: str = "mlx-community/whisper-large-v3-mlx"

# Groq cloud model (used on Windows / Intel Mac)
GROQ_MODEL: str = "whisper-large-v3"

RADIOLOGY_PROMPT: str = (
    "Radiology report dictation. "
    "Medical terms: pneumothorax, effusion, consolidation, atelectasis, "
    "cardiomegaly, mediastinum, hilum, pleural, pericardial, hepatic, "
    "splenic, renal, aortic, pulmonary embolism, haemorrhage, infarct, "
    "comminuted, displaced, cortex, diaphragm, costophrenic, trachea, "
    "lytic, sclerotic, lucency, opacity, infiltrate, nodule, mass."
)


# ── Data structures ───────────────────────────────────────────────────────────


@dataclass
class Word:
    text: str
    start: float
    end: float
    probability: float
    flagged: bool

    def __str__(self) -> str:
        return f"{self.text}[?]" if self.flagged else self.text


@dataclass
class TranscriptionResult:
    words: list[Word]
    language: str

    @property
    def text(self) -> str:
        return " ".join(w.text for w in self.words if w.text)

    @property
    def clean_text(self) -> str:
        parts = []
        for w in self.words:
            if not w.text:
                continue
            parts.append(f"[?{w.text}?]" if w.flagged else w.text)
        return " ".join(parts)

    @property
    def flagged_words(self) -> list[Word]:
        return [w for w in self.words if w.flagged]

    @property
    def flag_rate(self) -> float:
        if not self.words:
            return 0.0
        return len(self.flagged_words) / len(self.words)

    def is_empty(self) -> bool:
        return len(self.words) == 0


# ── Transcriber ───────────────────────────────────────────────────────────────


class Transcriber:
    """
    Cross-platform Whisper transcriber.

    On Apple Silicon: uses mlx-whisper (Metal GPU acceleration, fully local).
    On Windows/CPU:   calls Groq Whisper API (whisper-large-v3, same accuracy
                      as large model, ~1-2s per 10s chunk).

    Both backends return identical TranscriptionResult objects so the
    rest of the app doesn't need to know which backend is running.
    """

    HALLUCINATION_PHRASES = [
        "thank you",
        "thanks for watching",
        "subtitles by",
        "subscribe",
        "like and subscribe",
        "see you next time",
        "please subscribe",
        "for watching",
        "transcribed by",
        "hello",
        "bye",
        "goodbye",
    ]

    def __init__(
        self,
        confidence_threshold: float = CONFIDENCE_THRESHOLD,
        use_radiology_prompt: bool = True,
    ) -> None:
        self._confidence_threshold = confidence_threshold
        self._initial_prompt = RADIOLOGY_PROMPT if use_radiology_prompt else None

        backend = "mlx-whisper (Apple Silicon)" if IS_APPLE_SILICON else "Groq Whisper API"
        print(f"[transcribe] Backend: {backend}")

    # ── Public API ────────────────────────────────────────────────────────────

    def transcribe(self, audio: np.ndarray) -> TranscriptionResult:
        """
        Transcribe a mono float32 array at 16kHz.
        Automatically uses the right backend for this platform.
        """
        duration = len(audio) / SAMPLE_RATE
        if duration < MIN_AUDIO_SECONDS:
            return TranscriptionResult(words=[], language="en")

        if audio.dtype != np.float32:
            audio = audio.astype(np.float32)

        if IS_APPLE_SILICON:
            return self._transcribe_mlx(audio)
        else:
            return self._transcribe_groq(audio)

    # ── Apple Silicon backend ─────────────────────────────────────────────────

    def _transcribe_mlx(self, audio: np.ndarray) -> TranscriptionResult:
        import mlx_whisper  # type: ignore

        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=MLX_MODEL_REPO,
            word_timestamps=True,
            initial_prompt=self._initial_prompt,
            language="en",
            verbose=False,
            condition_on_previous_text=False,
        )

        words = self._extract_words_mlx(result)
        return TranscriptionResult(
            words=self._filter_hallucinations(words),
            language=result.get("language", "en"),
        )

    def _extract_words_mlx(self, result: dict) -> list[Word]:
        words: list[Word] = []
        for segment in result.get("segments", []):
            for w in segment.get("words", []):
                text = w.get("word", "").strip()
                if not text:
                    continue
                prob = float(w.get("probability", 1.0))
                words.append(Word(
                    text=text,
                    start=round(float(w.get("start", 0.0)), 3),
                    end=round(float(w.get("end", 0.0)), 3),
                    probability=round(prob, 4),
                    flagged=prob < self._confidence_threshold,
                ))
        return words

    # ── Groq cloud backend ────────────────────────────────────────────────────

    def _transcribe_groq(self, audio: np.ndarray) -> TranscriptionResult:
        from groq import Groq  # type: ignore

        api_key = os.environ.get("GROQ_API_KEY", "")
        if not api_key:
            raise RuntimeError(
                "GROQ_API_KEY is not set. "
                "Add it to your .env file: GROQ_API_KEY=gsk_..."
            )

        rms = float(np.sqrt(np.mean(audio ** 2)))
        if rms < 0.002:
            raise RuntimeError(
                f"No audio detected (level={rms:.4f}) — check microphone is not muted"
            )

        client = Groq(api_key=api_key)
        wav_bytes = _numpy_to_wav_bytes(audio)

        transcription = client.audio.transcriptions.create(
            file=("audio.wav", wav_bytes, "audio/wav"),
            model=GROQ_MODEL,
            response_format="verbose_json",
            timestamp_granularities=["word"],
            language="en",
            prompt=self._initial_prompt or "",
        )

        words = self._extract_words_groq(transcription)
        return TranscriptionResult(
            words=self._filter_hallucinations(words),
            language=getattr(transcription, "language", "en"),
        )

    def _extract_words_groq(self, transcription: object) -> list[Word]:
        words: list[Word] = []
        for w in getattr(transcription, "words", None) or []:
            text = getattr(w, "word", "").strip()
            if not text:
                continue
            words.append(Word(
                text=text,
                start=round(float(getattr(w, "start", 0.0)), 3),
                end=round(float(getattr(w, "end", 0.0)), 3),
                probability=1.0,
                flagged=False,
            ))

        # Fallback: if Groq returned no word timestamps but has full text, split it
        if not words:
            full_text = getattr(transcription, "text", "").strip()
            if full_text:
                words = [
                    Word(text=w, start=0.0, end=0.0, probability=1.0, flagged=False)
                    for w in full_text.split() if w.strip()
                ]

        return words

    # ── Hallucination filter ──────────────────────────────────────────────────

    @staticmethod
    def _clean(s: str) -> str:
        return re.sub(r"[^\w\s]", "", s.lower()).strip()

    def _filter_hallucinations(self, words: list[Word]) -> list[Word]:
        if not words:
            return words

        for phrase in self.HALLUCINATION_PHRASES:
            phrase_words = phrase.split()
            filtered: list[Word] = []
            i = 0
            while i < len(words):
                window = [
                    self._clean(words[j].text)
                    for j in range(i, min(i + len(phrase_words), len(words)))
                ]
                if window == phrase_words:
                    i += len(phrase_words)
                else:
                    filtered.append(words[i])
                    i += 1
            words = filtered

        deduped: list[Word] = []
        for w in words:
            if not deduped or self._clean(w.text) != self._clean(deduped[-1].text):
                deduped.append(w)
        words = deduped

        sentences: list[list[Word]] = []
        current: list[Word] = []
        for w in words:
            current.append(w)
            if re.search(r"[.?!]$", w.text.strip()):
                sentences.append(current)
                current = []
        if current:
            sentences.append(current)

        unique: list[list[Word]] = []
        for sent in sentences:
            sent_text = self._clean(" ".join(w.text for w in sent))
            if not unique or sent_text != self._clean(" ".join(w.text for w in unique[-1])):
                unique.append(sent)

        return [w for sent in unique for w in sent]


# ── Audio helpers ─────────────────────────────────────────────────────────────


def _numpy_to_wav_bytes(audio: np.ndarray, sample_rate: int = SAMPLE_RATE) -> bytes:
    """Convert a float32 mono numpy array to WAV bytes suitable for API upload."""
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)  # 16-bit PCM
        wf.setframerate(sample_rate)
        audio_int16 = (np.clip(audio, -1.0, 1.0) * 32767).astype(np.int16)
        wf.writeframes(audio_int16.tobytes())
    return buf.getvalue()


# ── Smoke test ────────────────────────────────────────────────────────────────


if __name__ == "__main__":
    import sounddevice as sd

    RECORD_SECONDS = 8
    backend = "mlx-whisper" if IS_APPLE_SILICON else "Groq Whisper API"

    print("=" * 60)
    print(f"NarrateRad -- transcribe.py smoke test ({backend})")
    print("=" * 60)
    print(f"\nRecording {RECORD_SECONDS} seconds -- dictate a finding.\n")

    audio = sd.rec(
        int(RECORD_SECONDS * SAMPLE_RATE),
        samplerate=SAMPLE_RATE,
        channels=1,
        dtype=np.float32,
    )
    sd.wait()

    print("Transcribing...\n")
    t = Transcriber()
    result = t.transcribe(audio[:, 0])

    if result.is_empty():
        print("No words detected.")
    else:
        print(f"Language : {result.language}")
        print(f"Words    : {len(result.words)}")
        print(f"Flagged  : {len(result.flagged_words)} ({result.flag_rate:.1%})")
        print()
        for w in result.words:
            flag = "  <- FLAGGED" if w.flagged else ""
            print(f"  {w.start:5.2f}s  {w.text:<25} p={w.probability:.3f}{flag}")
        print(f"\nText: {result.text}")
