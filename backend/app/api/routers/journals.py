"""Journals — the named containers a user files memories into.

The tier gate is a **count check on creation only**. Once a journal exists it
can always be listed, renamed, filed into and deleted, whatever the caller's
tier. That asymmetry is deliberate: someone whose premium lapses with eight
journals must not find their memories sorted into containers they can no longer
touch. Free is a ceiling on how many you may keep, never a wall around what you
already have.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status

from app.core.activity import track_activity
from app.core.entitlements import max_journals, tier_for
from app.core.security import CurrentUser, get_current_user
from app.models.journal import Journal, JournalCreate, JournalUpdate
from app.services.firestore import get_repository

router = APIRouter(prefix="/journals", tags=["journals"], dependencies=[Depends(track_activity)])


def _find_by_name(journals: list[Journal], name: str, *, excluding: str = "") -> Journal | None:
    """A journal with this name, case-insensitively.

    Two journals called "Travel" and "travel" would be indistinguishable in the
    picker and would split a user's filing in half without ever telling them.
    """
    folded = name.casefold()
    for j in journals:
        if j.id != excluding and j.name.casefold() == folded:
            return j
    return None


@router.get("", response_model=list[Journal])
def list_journals(user: CurrentUser = Depends(get_current_user)) -> list[Journal]:
    """Every journal the caller owns. Never gated — see the module docstring."""
    return get_repository().list_journals(user.uid)


@router.post("", response_model=Journal, status_code=status.HTTP_201_CREATED)
def create_journal(
    body: JournalCreate,
    user: CurrentUser = Depends(get_current_user),
) -> Journal:
    repo = get_repository()
    name = body.name.strip()
    # Literal codes: the named constants were renamed in Starlette and the old
    # spellings now warn. See `auth._require_email`.
    if not name:
        raise HTTPException(status_code=422, detail="A journal needs a name")

    existing = repo.list_journals(user.uid)
    if _find_by_name(existing, name) is not None:
        raise HTTPException(status_code=409, detail=f'You already have a journal called "{name}".')

    tier = tier_for(repo, user.uid)
    limit = max_journals(tier)
    if len(existing) >= limit:
        # Structured so the client can name the number. The app disables the
        # button at the same limit; this is the backstop, not the primary gate.
        raise HTTPException(
            status_code=403,
            detail={"error": "journal_limit", "limit": limit, "tier": tier.value},
        )

    now = datetime.now(timezone.utc)
    journal = Journal(
        id=uuid.uuid4().hex,
        name=name,
        color_index=body.color_index,
        created_at=now,
        updated_at=now,
    )
    return repo.save_journal(user.uid, journal)


@router.patch("/{journal_id}", response_model=Journal)
def update_journal(
    journal_id: str,
    body: JournalUpdate,
    user: CurrentUser = Depends(get_current_user),
) -> Journal:
    """Rename or recolour. Not gated — editing does not change the count."""
    repo = get_repository()
    journal = repo.get_journal(user.uid, journal_id)
    if journal is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Journal not found")

    if body.name is not None:
        name = body.name.strip()
        if not name:
            raise HTTPException(status_code=422, detail="A journal needs a name")
        if _find_by_name(repo.list_journals(user.uid), name, excluding=journal_id) is not None:
            raise HTTPException(
                status_code=409, detail=f'You already have a journal called "{name}".'
            )
        journal.name = name
    if body.color_index is not None:
        journal.color_index = body.color_index
    journal.updated_at = datetime.now(timezone.utc)
    return repo.save_journal(user.uid, journal)


@router.delete("/{journal_id}")
def delete_journal(
    journal_id: str,
    user: CurrentUser = Depends(get_current_user),
) -> dict:
    """Delete the journal; its memories become unfiled.

    Returns how many moved so the app can say so out loud. Nothing is deleted
    but the container itself — see `Repository.delete_journal`.
    """
    repo = get_repository()
    if repo.get_journal(user.uid, journal_id) is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Journal not found")
    return {"unfiled": repo.delete_journal(user.uid, journal_id)}
