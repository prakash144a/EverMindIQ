from __future__ import annotations

from fastapi import APIRouter, Depends, status

from app.core.security import CurrentUser, get_current_user
from app.services.firestore import get_repository

router = APIRouter(prefix="/account", tags=["account"])


@router.delete("", status_code=status.HTTP_204_NO_CONTENT)
def delete_account(user: CurrentUser = Depends(get_current_user)) -> None:
    """Purge all of the user's data: recordings, chunks/vectors, insights, feeds, settings.

    (Real mode additionally deletes the GCS audio objects for the user's prefix.)
    """
    get_repository().delete_user(user.uid)
