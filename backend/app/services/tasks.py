"""Async task dispatch for ingestion.

Mock mode runs the ingestion pipeline inline (so the recording is immediately indexed and tests are
deterministic). Real mode publishes a Pub/Sub message; a Cloud Run worker subscribes and calls
``process_recording``.
"""

from __future__ import annotations

from app.core.config import get_settings
from app.pipeline.ingest import process_recording


def enqueue_ingest(uid: str, recording_id: str) -> None:
    settings = get_settings()
    if settings.effective_mock:
        process_recording(uid, recording_id)
        return
    _publish_pubsub(uid, recording_id)  # pragma: no cover - real path


def _publish_pubsub(uid: str, recording_id: str) -> None:  # pragma: no cover
    import json

    from google.cloud import pubsub_v1

    settings = get_settings()
    publisher = pubsub_v1.PublisherClient()
    topic = publisher.topic_path(settings.gcp_project, settings.pubsub_ingest_topic)
    payload = json.dumps({"uid": uid, "recording_id": recording_id}).encode("utf-8")
    publisher.publish(topic, payload).result()
