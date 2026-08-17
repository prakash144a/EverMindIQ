"""Mock object-storage sink. Only mounted in mock mode.

Stands in for the GCS bucket a real signed upload URL would point to: the client PUTs audio bytes
here (resolved against the API base), and we stash them so the ingestion worker can read them back.
"""

from __future__ import annotations

from fastapi import APIRouter, Request

from app.services.storage import get_storage

router = APIRouter(tags=["mock"])


@router.put("/mock-storage/{bucket}/{obj_path:path}")
async def mock_put(bucket: str, obj_path: str, request: Request) -> dict:
    """Accept the client's audio bytes for a mock 'signed URL' upload."""
    body = await request.body()
    gs_path = f"gs://{bucket}/{obj_path}"
    get_storage().put_mock_bytes(gs_path, body)
    return {"audio_path": gs_path, "bytes": len(body)}
