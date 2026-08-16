from __future__ import annotations

import logging
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, status

from app.core.security import CurrentUser, get_current_user
from app.models.feedback import Feedback, FeedbackCreate
from app.services.firestore import get_repository

router = APIRouter(prefix="/feedback", tags=["feedback"])

log = logging.getLogger(__name__)


@router.post("", response_model=Feedback, status_code=status.HTTP_201_CREATED)
def create_feedback(
    body: FeedbackCreate,
    user: CurrentUser = Depends(get_current_user),
) -> Feedback:
    """Record a problem report or suggestion from inside the app."""
    item = Feedback(
        id=uuid.uuid4().hex,
        uid=user.uid,
        kind=body.kind,
        message=body.message,
        diagnostics=body.diagnostics,
        app_version=body.app_version,
        platform=body.platform,
        created_at=datetime.now(timezone.utc),
    )
    get_repository().add_feedback(item)
    # Also emit to Cloud Logging so reports are visible without querying the store.
    log.warning(
        "feedback kind=%s uid=%s platform=%s version=%s message=%s",
        item.kind.value,
        item.uid,
        item.platform,
        item.app_version,
        item.message,
    )
    return item


@router.get("", response_model=list[Feedback])
def list_feedback(user: CurrentUser = Depends(get_current_user)) -> list[Feedback]:
    """The caller's own reports, newest first."""
    return get_repository().list_feedback(user.uid)
