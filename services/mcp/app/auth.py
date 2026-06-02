"""FastAPI dependency: enforce Bearer token on every request."""
from __future__ import annotations

from fastapi import Header, HTTPException, status

from app.config import get_settings


def require_api_key(authorization: str = Header(...)) -> None:
    """Raise 401 if the Authorization header does not match MCP_API_KEY."""
    settings = get_settings()
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or token != settings.mcp_api_key:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing API key",
        )
