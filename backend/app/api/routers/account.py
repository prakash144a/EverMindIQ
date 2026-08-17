from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, status

from app.core.security import CurrentUser, get_current_user
from app.services.firestore import get_repository
from app.services.storage import get_storage

router = APIRouter(prefix="/account", tags=["account"])

log = logging.getLogger(__name__)


@router.delete("", status_code=status.HTTP_204_NO_CONTENT)
def delete_account(user: CurrentUser = Depends(get_current_user)) -> None:
    """Purge all of the user's data: recordings, chunks/vectors, insights, feeds,
    feedback, settings, and every audio object under the user's storage prefix.
    """
    get_repository().delete_user(user.uid)
    # By prefix rather than per recording: the metadata is already gone by now,
    # and the prefix also sweeps up blobs whose recording was lost or never
    # registered (an upload URL issued to a client that then crashed).
    try:
        get_storage().delete_user_prefix(user.uid)
    except Exception:  # pragma: no cover - real-path failure
        log.exception("failed to purge audio objects for uid %s", user.uid)
