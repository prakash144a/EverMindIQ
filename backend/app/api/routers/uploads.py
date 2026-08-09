from __future__ import annotations

from fastapi import APIRouter, Depends
from pydantic import BaseModel

from app.core.security import CurrentUser, get_current_user
from app.services.storage import SignedUpload, get_storage

router = APIRouter(prefix="/uploads", tags=["uploads"])


class UploadRequest(BaseModel):
    content_type: str = "audio/m4a"


class UploadResponse(BaseModel):
    upload_url: str
    audio_path: str
    method: str
    headers: dict


@router.post("", response_model=UploadResponse)
def create_upload(
    body: UploadRequest,
    user: CurrentUser = Depends(get_current_user),
) -> UploadResponse:
    """Issue a short-lived signed URL. The client PUTs the audio bytes directly to GCS."""
    up: SignedUpload = get_storage().create_upload(user.uid, body.content_type)
    return UploadResponse(
        upload_url=up.upload_url,
        audio_path=up.audio_path,
        method=up.method,
        headers=up.headers or {},
    )
