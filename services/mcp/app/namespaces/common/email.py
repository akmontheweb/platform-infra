"""common/send_email — send a transactional email via SMTP."""
from __future__ import annotations

import asyncio
import smtplib
from email.message import EmailMessage

import structlog
from fastapi import APIRouter, Depends
from fastmcp import FastMCP
from pydantic import BaseModel

from app.auth import require_api_key
from app.config import get_settings

log = structlog.get_logger(__name__)
router = APIRouter()


class SendEmailRequest(BaseModel):
    to: str
    subject: str
    body: str


async def _send_email(to: str, subject: str, body: str) -> dict:
    settings = get_settings()
    if not settings.smtp_host:
        log.info("send_email: SMTP not configured — suppressed", to=to)
        return {"ok": False, "reason": "smtp_not_configured"}

    def _sync() -> None:
        msg = EmailMessage()
        msg.set_content(body)
        msg["Subject"] = subject
        msg["From"] = settings.smtp_from
        msg["To"] = to
        with smtplib.SMTP(settings.smtp_host, settings.smtp_port) as server:
            if settings.smtp_user and settings.smtp_password:
                server.starttls()
                server.login(settings.smtp_user, settings.smtp_password)
            server.send_message(msg)

    try:
        await asyncio.to_thread(_sync)
        log.info("send_email: sent", to=to)
        return {"ok": True}
    except Exception as exc:  # noqa: BLE001
        log.warning("send_email: failed", to=to, error=str(exc))
        return {"ok": False, "reason": str(exc)}


# ── REST endpoint ─────────────────────────────────────────────────────────────

@router.post("/send_email")
async def http_send_email(
    req: SendEmailRequest,
    _: None = Depends(require_api_key),
) -> dict:
    return await _send_email(to=req.to, subject=req.subject, body=req.body)


# ── MCP tool registration ─────────────────────────────────────────────────────

def register_mcp(mcp: FastMCP) -> None:
    @mcp.tool(name="common_send_email")
    async def send_email(to: str, subject: str, body: str) -> dict:
        """Send a transactional email via SMTP.

        Args:
            to: Recipient email address.
            subject: Email subject line.
            body: Plain-text email body.
        """
        return await _send_email(to=to, subject=subject, body=body)
