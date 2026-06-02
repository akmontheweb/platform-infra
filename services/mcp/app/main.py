"""Platform MCP — FastAPI app exposing:
  • POST /tools/{tool}  — REST interface for server-to-server calls
  • /mcp                — full MCP protocol endpoint for AI clients
  • GET  /health        — liveness probe
"""
from __future__ import annotations

from contextlib import asynccontextmanager

import structlog
from fastapi import FastAPI
from fastmcp import FastMCP
from fastmcp.utilities.lifespan import combine_lifespans

from app.namespaces.common import email as email_ns
from app.namespaces.common import sms as sms_ns
from app.namespaces.common import search as search_ns
from app.namespaces.common import audio as audio_ns

log = structlog.get_logger(__name__)

# ── MCP server (for AI clients) ──────────────────────────────────────────────
mcp = FastMCP(
    name="platform-mcp",
    instructions=(
        "General-purpose platform tools shared across all projects. "
        "Namespace: common."
    ),
)

email_ns.register_mcp(mcp)
sms_ns.register_mcp(mcp)
search_ns.register_mcp(mcp)
audio_ns.register_mcp(mcp)


# ── FastAPI app ───────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):  # noqa: RUF029
    log.info("platform-mcp ready")
    yield


mcp_http_app = mcp.http_app(path="/")

app = FastAPI(
    title="Platform MCP",
    version="0.1.0",
    lifespan=combine_lifespans(lifespan, mcp_http_app.lifespan),
)

# Mount MCP protocol endpoint (Streamable HTTP transport)
app.mount("/mcp", mcp_http_app)

# REST routers (used by orchestrator via httpx)
app.include_router(email_ns.router, prefix="/tools")
app.include_router(sms_ns.router, prefix="/tools")
app.include_router(search_ns.router, prefix="/tools")
app.include_router(audio_ns.router, prefix="/tools")


@app.get("/health")
async def health() -> dict:
    return {"status": "ok", "service": "platform-mcp"}
