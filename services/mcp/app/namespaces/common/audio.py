"""common/transcribe_audio — transcribe audio via LiteLLM Whisper endpoint."""
from __future__ import annotations

import structlog
import httpx
from fastapi import APIRouter, Depends, HTTPException
from fastmcp import FastMCP
from pydantic import BaseModel

from app.auth import require_api_key
from app.config import get_settings

log = structlog.get_logger(__name__)
router = APIRouter()


class TranscribeAudioRequest(BaseModel):
    audio_url: str
    language: str = "en"


async def _transcribe_audio(audio_url: str, language: str = "en") -> dict:
    settings = get_settings()
    if not settings.litellm_proxy_url:
        raise HTTPException(status_code=503, detail="LiteLLM proxy not configured")

    async with httpx.AsyncClient(timeout=60) as client:
        # Download the audio file
        dl = await client.get(audio_url)
        dl.raise_for_status()
        audio_bytes = dl.content
        filename = audio_url.rstrip("/").split("/")[-1] or "audio.wav"

        # POST to LiteLLM Whisper endpoint
        headers: dict[str, str] = {}
        if settings.litellm_api_key:
            headers["Authorization"] = f"Bearer {settings.litellm_api_key}"
        resp = await client.post(
            f"{settings.litellm_proxy_url}/audio/transcriptions",
            files={"file": (filename, audio_bytes, "audio/wav")},
            data={"model": "whisper-1", "language": language},
            headers=headers,
        )
        resp.raise_for_status()
        data = resp.json()

    transcript = data.get("text", "")
    log.info("transcribe_audio: done", chars=len(transcript))
    return {"transcript": transcript, "language": language}


# ── REST endpoint ─────────────────────────────────────────────────────────────

@router.post("/transcribe_audio")
async def http_transcribe_audio(
    req: TranscribeAudioRequest,
    _: None = Depends(require_api_key),
) -> dict:
    return await _transcribe_audio(audio_url=req.audio_url, language=req.language)


# ── MCP tool registration ─────────────────────────────────────────────────────

def register_mcp(mcp: FastMCP) -> None:
    @mcp.tool(name="common_transcribe_audio")
    async def transcribe_audio(audio_url: str, language: str = "en") -> dict:
        """Transcribe audio from a URL using Whisper via the LiteLLM proxy.

        Args:
            audio_url: Publicly accessible URL of the audio file.
            language: BCP-47 language code (default 'en').
        """
        return await _transcribe_audio(audio_url=audio_url, language=language)
