from __future__ import annotations

from fastapi import APIRouter, Depends

from app.core.activity import track_activity
from app.core.security import CurrentUser, get_current_user
from app.models.user import UserSettings
from app.services.firestore import get_repository

router = APIRouter(prefix="/settings", tags=["settings"], dependencies=[Depends(track_activity)])


@router.get("", response_model=UserSettings)
def get_settings_doc(user: CurrentUser = Depends(get_current_user)) -> UserSettings:
    return get_repository().get_settings_doc(user.uid)


@router.put("", response_model=UserSettings)
def update_settings_doc(
    body: UserSettings,
    user: CurrentUser = Depends(get_current_user),
) -> UserSettings:
    """Save settings, keeping any field the caller didn't send.

    A client only knows the fields it shipped with, so an older build doing
    GET -> toggle -> PUT drops keys added since. Without the merge that silently
    resets them: flipping a switch on an old phone would reset the theme chosen
    on a new one. ``exclude_unset`` separates "absent from the JSON" from "sent
    as the default", so only genuinely omitted keys fall back to the stored one.
    """
    repo = get_repository()
    merged = repo.get_settings_doc(user.uid).model_copy(
        update=body.model_dump(exclude_unset=True)
    )
    return repo.save_settings_doc(user.uid, merged)
