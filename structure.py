"""
structure.py — NarrateRad
==========================
LLM structuring module — converts raw radiology dictation into a
preliminary report formatted for Medical Transcriptionist (MT) handover.

Uses Claude API (claude-haiku-4-5) for fast cloud-based structuring.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import AsyncGenerator

import anthropic

# ── Config ────────────────────────────────────────────────────────────────────

MODEL: str = "claude-haiku-4-5"


# ── Patient info ──────────────────────────────────────────────────────────────


@dataclass
class PatientInfo:
    name: str = ""
    age: str = ""
    mr_number: str = ""
    referring_physician: str = ""

    def header(self) -> str:
        """Renders the patient demographics block for the report header."""
        lines = ["PRELIMINARY DICTATION", "─" * 40]
        if self.name:
            lines.append(f"Patient Name:        {self.name}")
        if self.age:
            lines.append(f"Age:                 {self.age}")
        if self.mr_number:
            lines.append(f"MR Number:           {self.mr_number}")
        if self.referring_physician:
            lines.append(f"Referring Physician: {self.referring_physician}")
        lines.append("─" * 40)
        return "\n".join(lines)

    def is_empty(self) -> bool:
        return not any([self.name, self.age, self.mr_number, self.referring_physician])


# ── System prompt ─────────────────────────────────────────────────────────────

SYSTEM_PROMPT = """You are a radiology report assistant preparing a preliminary dictation for a Medical Transcriptionist (MT). Your task is to structure raw dictation into a clear, well-organised preliminary report that the MT can use to fill in the hospital reporting system.

Output the report using exactly these section headers in this order:

PROCEDURE:
[The imaging study or interventional procedure performed. For diagnostic imaging: modality, body part, and technique. For IR procedures: procedure name, access site, materials used (contrast, devices), and any immediate complications.]

CLINICAL INDICATION:
[The reason for the study. Write "Not provided" if not mentioned.]

FINDINGS:
[Organise findings by organ system. Each system on a new line. Use clear, formal radiology language. For IR procedures, include: pre-procedure status, intra-procedure findings, post-procedure status, and any complications.]

IMPRESSION:
[Concise numbered summary of key findings and clinical significance. Maximum 5 points. For IR: include technical success, clinical outcome, and follow-up recommendation.]

─────────────────────────────────
For MT: Please transcribe above findings into the reporting system exactly as dictated. Flag any unclear terms.
─────────────────────────────────

Strict rules:
- CRITICAL: Never invent findings not present in the dictation. Never add bilateral or any laterality unless explicitly stated by the radiologist. If only one side is mentioned, only write that side.
- If the radiologist says right only, write right only. Never assume the other side is involved.
- Never omit findings that are present
- Preserve all laterality exactly as dictated — if ambiguous, add [LATERALITY CHECK]
- Use formal radiology terminology
- If a section cannot be filled from the dictation, write "Refer to dictation"
- Output the structured report only — no commentary or preamble"""


# ── Exceptions ────────────────────────────────────────────────────────────────


class ClaudeNotConfiguredError(Exception):
    def __str__(self) -> str:
        return (
            "ANTHROPIC_API_KEY is not set.\n"
            "Add it to your .env file: ANTHROPIC_API_KEY=sk-ant-..."
        )


# ── Helpers ───────────────────────────────────────────────────────────────────


def _get_api_key() -> str:
    key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not key:
        raise ClaudeNotConfiguredError()
    return key


def _build_prompt(dictation: str, patient: PatientInfo | None) -> str:
    parts = []
    if patient and not patient.is_empty():
        parts.append(patient.header())
        parts.append("")
    parts.append("Structure this dictation into a preliminary report for MT handover:")
    parts.append("")
    parts.append(dictation)
    return "\n".join(parts)


# ── Core functions ────────────────────────────────────────────────────────────


def structure_report(dictation: str, patient: PatientInfo | None = None) -> str:
    """Convert raw dictation into an MT-ready preliminary report. Synchronous."""
    dictation = dictation.strip()
    if not dictation:
        return "No dictation provided."

    client = anthropic.Anthropic(api_key=_get_api_key())
    message = client.messages.create(
        model=MODEL,
        max_tokens=1024,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": _build_prompt(dictation, patient)}],
    )
    result = message.content[0].text.strip()

    if patient and not patient.is_empty():
        return patient.header() + "\n\n" + result
    return result


async def structure_report_stream(
    dictation: str, patient: PatientInfo | None = None
) -> AsyncGenerator[str, None]:
    """Convert raw dictation into a preliminary report, streaming output."""
    dictation = dictation.strip()
    if not dictation:
        yield "No dictation provided."
        return

    if patient and not patient.is_empty():
        yield patient.header() + "\n\n"

    api_key = _get_api_key()
    async with anthropic.AsyncAnthropic(api_key=api_key) as client:
        async with client.messages.stream(
            model=MODEL,
            max_tokens=1024,
            system=SYSTEM_PROMPT,
            messages=[{"role": "user", "content": _build_prompt(dictation, patient)}],
        ) as stream:
            async for text in stream.text_stream:
                yield text


# ── Smoke test ────────────────────────────────────────────────────────────────


if __name__ == "__main__":
    import asyncio

    patient = PatientInfo(
        name="Ahmed Khan",
        age="52 years",
        mr_number="MR-2024-00451",
        referring_physician="Dr. Sarah Ahmed",
    )

    dictation = (
        "CT chest with contrast. Moderate right pleural effusion. "
        "No pneumothorax. Heart size is normal. Mediastinum is central. "
        "No significant lymphadenopathy. Liver and spleen appear normal "
        "on the limited views. Impression: moderate right pleural effusion, "
        "recommend follow-up."
    )

    print("=" * 60)
    print("NarrateRad -- structure.py smoke test (Claude API)")
    print("=" * 60)

    async def run() -> None:
        try:
            async for chunk in structure_report_stream(dictation, patient):
                print(chunk, end="", flush=True)
            print("\n")
        except ClaudeNotConfiguredError as e:
            print(f"\nError: {e}")

    asyncio.run(run())
