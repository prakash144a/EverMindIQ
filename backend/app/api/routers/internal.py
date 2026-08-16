"""Internal worker endpoint for Pub/Sub push delivery (real mode).

The ingestion subscription pushes a message here after audio upload; we decode it and run the
pipeline. In production this route is protected by the subscription's OIDC token (verified at the
Cloud Run ingress / IAM layer). It is a no-op path in mock mode, where ingestion runs inline.
"""

from __future__ import annotations

import base64
import json
import logging

from fastapi import APIRouter, HTTPException, Request, status

from app.pipeline.ingest import RecordingNotFound, process_recording

router = APIRouter(prefix="/internal", tags=["internal"])

log = logging.getLogger(__name__)


@router.post("/ingest", status_code=status.HTTP_204_NO_CONTENT)
async def ingest_push(request: Request) -> None:
    envelope = await request.json()
    message = (envelope or {}).get("message")
    if not message or "data" not in message:
        raise HTTPException(status_code=400, detail="expected a Pub/Sub push envelope")
    try:
        payload = json.loads(base64.b64decode(message["data"]).decode("utf-8"))
        uid = payload["uid"]
        recording_id = payload["recording_id"]
    except (KeyError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=f"bad message payload: {exc}") from exc

    # Ack by returning 2xx. Raising would nack and trigger Pub/Sub retry.
    try:
        process_recording(uid, recording_id)
    except RecordingNotFound as exc:
        # Permanent failure: the recording is gone, so every retry will fail the
        # same way. Nacking would leave the message redelivering until it expires,
        # burning invocations and drowning the logs. Ack and move on.
        log.warning("dropping unprocessable ingest message: %s", exc)
