"""Runtime settings for platform-mcp, loaded from environment / .env."""
from __future__ import annotations

from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    mcp_api_key: str = Field("", validation_alias="MCP_API_KEY")

    # ── SMTP ──────────────────────────────────────────────────────────────────
    smtp_host: str = Field("", validation_alias="SMTP_HOST")
    smtp_port: int = Field(587, validation_alias="SMTP_PORT")
    smtp_user: str = Field("", validation_alias="SMTP_USER")
    smtp_password: str = Field("", validation_alias="SMTP_PASSWORD")
    smtp_from: str = Field("noreply@example.com", validation_alias="SMTP_FROM")

    # ── Twilio ────────────────────────────────────────────────────────────────
    twilio_account_sid: str = Field("", validation_alias="TWILIO_ACCOUNT_SID")
    twilio_auth_token: str = Field("", validation_alias="TWILIO_AUTH_TOKEN")
    twilio_phone_number: str = Field("", validation_alias="TWILIO_PHONE_NUMBER")

    # ── Tavily (web search + nearby places) ──────────────────────────────────
    tavily_api_key: str = Field("", validation_alias="TAVILY_API_KEY")

    # ── LiteLLM proxy (Whisper transcription) ────────────────────────────────
    litellm_proxy_url: str = Field("", validation_alias="LITELLM_PROXY_URL")
    litellm_api_key: str = Field("", validation_alias="LITELLM_API_KEY")


@lru_cache
def get_settings() -> Settings:
    return Settings()
