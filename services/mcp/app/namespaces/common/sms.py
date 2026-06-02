"""common/send_sms — send an SMS via Twilio."""
from __future__ import annotations

import asyncio

import structlog
from fastapi import APIRouter, Depends
from fastmcp import FastMCP
from pydantic import BaseModel

from app.auth import require_api_key
from app.config import get_settings

log = structlog.get_logger(__name__)
router = APIRouter()


class SendSmsRequest(BaseModel):
    to: str
    body: str


async def _send_sms(to: str, body: str) -> dict:
    settings = get_settings()
    if not (settings.twilio_account_sid and settings.twilio_auth_token and settings.twilio_phone_number):
        log.info("send_sms: Twilio not configured — suppressed", to=to)
        return {"ok": False, "reason": "twilio_not_configured"}

    sid = settings.twilio_account_sid
    token = settings.twilio_auth_token
    from_num = settings.twilio_phone_number

    def _sync() -> None:
        from twilio.rest import Client as TwilioClient  # noqa: PLC0415
        TwilioClient(sid, token).messages.create(
            to=to, from_=from_num, body=body[:160]
        )

    try:
        await asyncio.to_thread(_sync)
        log.info("send_sms: sent", to=to)
        return {"ok": True}
    except Exception as exc:  # noqa: BLE001
        log.warning("send_sms: failed", to=to, error=str(exc))
        return {"ok": False, "reason": str(exc)}


# ── REST endpoint ─────────────────────────────────────────────────────────────

@router.post("/send_sms")
async def http_send_sms(
    req: SendSmsRequest,
    _: None = Depends(require_api_key),
) -> dict:
    return await _send_sms(to=req.to, body=req.body)


# ── MCP tool registration ─────────────────────────────────────────────────────

def register_mcp(mcp: FastMCP) -> None:
    @mcp.tool(name="common_send_sms")
    async def send_sms(to: str, body: str) -> dict:
        """Send an SMS message via Twilio.

        Args:
            to: Recipient E.164 phone number (e.g. '+14155552671').
            body: Message text (truncated to 160 chars automatically).
        """
        return await _send_sms(to=to, body=body)
