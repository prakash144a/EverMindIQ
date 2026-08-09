"""Audio object storage on GCS.

Real mode issues short-lived V4 signed URLs against a CMEK-encrypted bucket, so the client uploads
directly without holding broad storage credentials. Mock mode returns fake but well-formed URLs and
records the object path so the rest of the flow works end-to-end in tests.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass

from app.core.config import Settings, get_settings


@dataclass
class SignedUpload:
    upload_url: str
    audio_path: str  # gs://bucket/object
    method: str = "PUT"
    headers: dict | None = None


class StorageService:
    def __init__(self, settings: Settings | None = None) -> None:
        self.settings = settings or get_settings()
        self._mock_objects: set[str] = set()

    def _object_name(self, uid: str) -> str:
        return f"users/{uid}/audio/{uuid.uuid4().hex}.m4a"

    def create_upload(self, uid: str, content_type: str = "audio/m4a") -> SignedUpload:
        obj = self._object_name(uid)
        gs_path = f"gs://{self.settings.audio_bucket}/{obj}"
        if self.settings.effective_mock:
            self._mock_objects.add(gs_path)
            return SignedUpload(
                upload_url=f"https://mock-upload.local/{self.settings.audio_bucket}/{obj}",
                audio_path=gs_path,
                headers={"Content-Type": content_type},
            )
        return self._gcs_signed_upload(obj, content_type)  # pragma: no cover - real path

    def signed_download_url(self, gs_path: str) -> str:
        if self.settings.effective_mock:
            obj = gs_path.split(f"{self.settings.audio_bucket}/", 1)[-1]
            return f"https://mock-download.local/{self.settings.audio_bucket}/{obj}"
        return self._gcs_signed_download(gs_path)  # pragma: no cover - real path

    def read_bytes(self, gs_path: str) -> bytes:
        """Used by the ingestion worker to fetch audio for transcription."""
        if self.settings.effective_mock:
            # In mock mode there is no real audio; the transcriber is seeded separately.
            return b""
        return self._gcs_read(gs_path)  # pragma: no cover - real path

    # -- real (GCS) --------------------------------------------------------
    def _client(self):  # pragma: no cover - real path
        from google.cloud import storage

        return storage.Client(project=self.settings.gcp_project)

    def _gcs_signed_upload(self, obj: str, content_type: str) -> SignedUpload:  # pragma: no cover
        from datetime import timedelta

        blob = self._client().bucket(self.settings.audio_bucket).blob(obj)
        url = blob.generate_signed_url(
            version="v4",
            expiration=timedelta(seconds=self.settings.signed_url_ttl_seconds),
            method="PUT",
            content_type=content_type,
        )
        return SignedUpload(
            upload_url=url,
            audio_path=f"gs://{self.settings.audio_bucket}/{obj}",
            headers={"Content-Type": content_type},
        )

    def _gcs_signed_download(self, gs_path: str) -> str:  # pragma: no cover
        from datetime import timedelta

        obj = gs_path.split(f"{self.settings.audio_bucket}/", 1)[-1]
        blob = self._client().bucket(self.settings.audio_bucket).blob(obj)
        return blob.generate_signed_url(
            version="v4",
            expiration=timedelta(seconds=self.settings.signed_url_ttl_seconds),
            method="GET",
        )

    def _gcs_read(self, gs_path: str) -> bytes:  # pragma: no cover
        obj = gs_path.split(f"{self.settings.audio_bucket}/", 1)[-1]
        return self._client().bucket(self.settings.audio_bucket).blob(obj).download_as_bytes()


_storage_singleton: StorageService | None = None


def get_storage() -> StorageService:
    global _storage_singleton
    if _storage_singleton is None:
        _storage_singleton = StorageService()
    return _storage_singleton
