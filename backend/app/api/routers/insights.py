from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status

from app.core.security import CurrentUser, get_current_user
from app.models.insight import Insight, InsightRequest
from app.pipeline.insights import generate_insight

router = APIRouter(prefix="/insights", tags=["insights"])


@router.post("", response_model=Insight)
def get_insight(
    body: InsightRequest,
    user: CurrentUser = Depends(get_current_user),
) -> Insight:
    try:
        return generate_insight(user.uid, body)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
