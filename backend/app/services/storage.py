"""Audio object storage on GCS.

Real mode issues short-lived V4 signed URLs against a CMEK-encrypted bucket, so the client uploads
directly without holding broad storage credentials. Mock mode returns fake but well-formed URLs and
records the object path so the rest of the flow works end-to-end in tests.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass

from app.core.config import Settings, get_settings
from app.core.media import ext_for_content_type


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
        # In mock mode, bytes PUT to the mock upload URL land here, keyed by gs:// path.
        self._mock_blobs: dict[str, bytes] = {}

    def _user_prefix(self, uid: str) -> str:
        return f"users/{uid}/audio/"

    def _object_name(self, uid: str, content_type: str) -> str:
        # The extension has to follow the actual container: it is what playback
        # and transcription both read the MIME type back off of.
        return f"{self._user_prefix(uid)}{uuid.uuid4().hex}{ext_for_content_type(content_type)}"

    def create_upload(self, uid: str, content_type: str = "audio/m4a") -> SignedUpload:
        obj = self._object_name(uid, content_type)
        gs_path = f"gs://{self.settings.audio_bucket}/{obj}"
        if self.settings.effective_mock:
            self._mock_objects.add(gs_path)
            # A backend-relative URL: the client resolves it against the API base and PUTs the
            # bytes to /mock-storage/... which stores them (see put_mock_bytes). This mirrors the
            # real signed-URL flow (direct client→storage PUT) without needing a real GCS bucket.
            return SignedUpload(
                upload_url=f"/mock-storage/{self.settings.audio_bucket}/{obj}",
                audio_path=gs_path,
                headers={"Content-Type": content_type},
            )
        return self._gcs_signed_upload(obj, content_type)  # pragma: no cover - real path

    def signed_download_url(self, gs_path: str) -> str:
        if self.settings.effective_mock:
            obj = gs_path.split(f"{self.settings.audio_bucket}/", 1)[-1]
            return f"https://mock-download.local/{self.settings.audio_bucket}/{obj}"
        return self._gcs_signed_download(gs_path)  # pragma: no cover - real path

    def put_mock_bytes(self, gs_path: str, data: bytes) -> None:
        """Store bytes uploaded to the mock signed URL (mock mode only)."""
        self._mock_objects.add(gs_path)
        self._mock_blobs[gs_path] = data

    def read_bytes(self, gs_path: str) -> bytes:
        """Used by the ingestion worker to fetch audio for transcription."""
        if self.settings.effective_mock:
            # Return whatever the client uploaded to the mock URL (the mock transcriber only uses
            # its length; real speech-to-text is a real-mode concern).
            return self._mock_blobs.get(gs_path, b"")
        return self._gcs_read(gs_path)  # pragma: no cover - real path

    # -- deletion ----------------------------------------------------------
    def delete_object(self, gs_path: str) -> None:
        """Delete one audio blob. Missing objects are not an error (delete is idempotent)."""
        if self.settings.effective_mock:
            self._mock_objects.discard(gs_path)
            self._mock_blobs.pop(gs_path, None)
            return
        self._gcs_delete(gs_path)  # pragma: no cover - real path

    def delete_user_prefix(self, uid: str) -> int:
        """Delete every audio object owned by `uid`. Returns how many were removed."""
        prefix = f"gs://{self.settings.audio_bucket}/{self._user_prefix(uid)}"
        if self.settings.effective_mock:
            paths = [p for p in self._mock_objects if p.startswith(prefix)]
            for p in paths:
                self._mock_objects.discard(p)
                self._mock_blobs.pop(p, None)
            return len(paths)
        return self._gcs_delete_prefix(uid)  # pragma: no cover - real path

    # -- real (GCS) --------------------------------------------------------
    def _client(self):  # pragma: no cover - real path
        from google.cloud import storage

        return storage.Client(project=self.settings.gcp_project)

    def _signer(self):  # pragma: no cover - real path
        """Ambient credentials for V4 signing.

        On Cloud Run the runtime credentials are a bare OAuth token with no
        private key, so ``generate_signed_url`` must sign via the IAM
        ``signBlob`` API. Passing ``service_account_email`` + ``access_token``
        selects that path; it requires the service account to hold
        ``roles/iam.serviceAccountTokenCreator`` on itself.
        """
        from google.auth import default
        from google.auth.transport.requests import Request

        creds, _ = default()
        creds.refresh(Request())
        return creds

    def _gcs_signed_upload(self, obj: str, content_type: str) -> SignedUpload:  # pragma: no cover
        from datetime import timedelta

        creds = self._signer()
        blob = self._client().bucket(self.settings.audio_bucket).blob(obj)
        url = blob.generate_signed_url(
            version="v4",
            expiration=timedelta(seconds=self.settings.signed_url_ttl_seconds),
            method="PUT",
            content_type=content_type,
            service_account_email=creds.service_account_email,
            access_token=creds.token,
        )
        return SignedUpload(
            upload_url=url,
            audio_path=f"gs://{self.settings.audio_bucket}/{obj}",
            headers={"Content-Type": content_type},
        )

    def _gcs_signed_download(self, gs_path: str) -> str:  # pragma: no cover
        from datetime import timedelta

        creds = self._signer()
        obj = gs_path.split(f"{self.settings.audio_bucket}/", 1)[-1]
        blob = self._client().bucket(self.settings.audio_bucket).blob(obj)
        return blob.generate_signed_url(
            version="v4",
            expiration=timedelta(seconds=self.settings.signed_url_ttl_seconds),
            method="GET",
            service_account_email=creds.service_account_email,
            access_token=creds.token,
        )

    def _gcs_read(self, gs_path: str) -> bytes:  # pragma: no cover
        obj = gs_path.split(f"{self.settings.audio_bucket}/", 1)[-1]
        return self._client().bucket(self.settings.audio_bucket).blob(obj).download_as_bytes()

    def _gcs_delete(self, gs_path: str) -> None:  # pragma: no cover
        from google.cloud.exceptions import NotFound

        obj = gs_path.split(f"{self.settings.audio_bucket}/", 1)[-1]
        try:
            self._client().bucket(self.settings.audio_bucket).blob(obj).delete()
        except NotFound:
            pass

    def _gcs_delete_prefix(self, uid: str) -> int:  # pragma: no cover
        bucket = self._client().bucket(self.settings.audio_bucket)
        count = 0
        for blob in self._client().list_blobs(bucket, prefix=self._user_prefix(uid)):
            blob.delete()
            count += 1
        return count


_storage_singleton: StorageService | None = None


def get_storage() -> StorageService:
    global _storage_singleton
    if _storage_singleton is None:
        _storage_singleton = StorageService()
    return _storage_singleton
