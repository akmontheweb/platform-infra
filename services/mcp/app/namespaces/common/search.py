"""common/web_search and common/find_nearby_places — powered by Tavily."""
from __future__ import annotations

import math

import structlog
from fastapi import APIRouter, Depends, HTTPException
from fastmcp import FastMCP
from pydantic import BaseModel

from app.auth import require_api_key
from app.config import get_settings

log = structlog.get_logger(__name__)
router = APIRouter()

_DEFAULT_MAX_RESULTS = 5
_DEFAULT_RADIUS_KM = 2.0


# ── Shared helpers ────────────────────────────────────────────────────────────

def _haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    R = 6_371.0
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = (
        math.sin(dlat / 2) ** 2
        + math.cos(math.radians(lat1))
        * math.cos(math.radians(lat2))
        * math.sin(dlon / 2) ** 2
    )
    return R * 2 * math.asin(math.sqrt(a))


def _get_tavily_client():
    settings = get_settings()
    if not settings.tavily_api_key:
        raise HTTPException(status_code=503, detail="Tavily not configured")
    from tavily import TavilyClient  # noqa: PLC0415
    return TavilyClient(api_key=settings.tavily_api_key)


# ── web_search ────────────────────────────────────────────────────────────────

class WebSearchRequest(BaseModel):
    query: str
    max_results: int = _DEFAULT_MAX_RESULTS


async def _web_search(query: str, max_results: int = _DEFAULT_MAX_RESULTS) -> dict:
    client = _get_tavily_client()
    try:
        raw = client.search(query=query, max_results=max_results)
        results = [
            {
                "title": r.get("title", ""),
                "url": r.get("url", ""),
                "content": r.get("content", ""),
            }
            for r in raw.get("results", [])
        ]
        return {"results": results}
    except HTTPException:
        raise
    except Exception as exc:  # noqa: BLE001
        log.warning("web_search: failed", error=str(exc))
        return {"results": [], "error": str(exc)}


@router.post("/web_search")
async def http_web_search(
    req: WebSearchRequest,
    _: None = Depends(require_api_key),
) -> dict:
    return await _web_search(query=req.query, max_results=req.max_results)


# ── find_nearby_places ────────────────────────────────────────────────────────

class FindNearbyPlacesRequest(BaseModel):
    lat: float
    lon: float
    query: str
    radius_km: float = _DEFAULT_RADIUS_KM


async def _find_nearby_places(
    lat: float, lon: float, query: str, radius_km: float = _DEFAULT_RADIUS_KM
) -> dict:
    client = _get_tavily_client()
    try:
        raw = client.search(
            query=f"{query} near {lat},{lon}", max_results=5
        )
        places: list[dict] = []
        for r in raw.get("results", []):
            name = r.get("title", query)
            place_lat = r.get("latitude") or r.get("lat")
            place_lon = r.get("longitude") or r.get("lon") or r.get("lng")
            if place_lat and place_lon:
                d = _haversine_km(lat, lon, float(place_lat), float(place_lon))
                if d <= radius_km:
                    places.append({"name": name, "distance_km": round(d, 1)})
            elif not places:
                # No coords — use first result as best-effort proximity signal
                places.append({"name": name, "distance_km": None})
        return {"places": places}
    except HTTPException:
        raise
    except Exception as exc:  # noqa: BLE001
        log.warning("find_nearby_places: failed", error=str(exc))
        return {"places": [], "error": str(exc)}


@router.post("/find_nearby_places")
async def http_find_nearby_places(
    req: FindNearbyPlacesRequest,
    _: None = Depends(require_api_key),
) -> dict:
    return await _find_nearby_places(
        lat=req.lat, lon=req.lon, query=req.query, radius_km=req.radius_km
    )


# ── MCP tool registrations ────────────────────────────────────────────────────

def register_mcp(mcp: FastMCP) -> None:
    @mcp.tool(name="common_web_search")
    async def web_search(query: str, max_results: int = _DEFAULT_MAX_RESULTS) -> dict:
        """Search the web using Tavily and return structured results.

        Args:
            query: Search query string.
            max_results: Maximum number of results to return (default 5).
        """
        return await _web_search(query=query, max_results=max_results)

    @mcp.tool(name="common_find_nearby_places")
    async def find_nearby_places(
        lat: float, lon: float, query: str, radius_km: float = _DEFAULT_RADIUS_KM
    ) -> dict:
        """Find places matching a query that are near the given coordinates.

        Args:
            lat: Latitude of the user's current location.
            lon: Longitude of the user's current location.
            query: What to search for (e.g. 'pharmacy', 'hardware store').
            radius_km: Maximum distance in kilometres (default 2.0).
        """
        return await _find_nearby_places(lat=lat, lon=lon, query=query, radius_km=radius_km)
