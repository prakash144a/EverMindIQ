from __future__ import annotations

from fastapi import APIRouter, Depends

from app.core.security import CurrentUser, get_current_user
from app.models.user import UserSettings
from app.services.firestore import get_repository

router = APIRouter(prefix="/settings", tags=["settings"])


@router.get("", response_model=UserSettings)
def get_settings_doc(user: CurrentUser = Depends(get_current_user)) -> UserSettings:
    return get_repository().get_settings_doc(user.uid)


@router.put("", response_model=UserSettings)
def update_settings_doc(
    body: UserSettings,
    user: CurrentUser = Depends(get_current_user),
) -> UserSettings:
    return get_repository().save_settings_doc(user.uid, body)
