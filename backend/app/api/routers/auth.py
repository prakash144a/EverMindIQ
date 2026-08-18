"""Email verification, account creation, and restore-after-reinstall.

The uid is never taken from the request. On signup the caller's existing
anonymous uid is reused, so recordings stay attached with no migration. On
restore the target account is looked up from the *verified* email, never from
anything the caller supplies.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field

from app.core.activity import track_activity
from app.core.entitlements import tier_for
from app.core.security import CurrentUser, get_current_user
from app.models.user import ProfileView, UserProfile, is_email, normalize_email
from app.services.firestore import get_repository
from app.services.otp import OtpError, get_otp_service

router = APIRouter(prefix="/auth", tags=["auth"])
profile_router = APIRouter(prefix="/profile", tags=["auth"], dependencies=[Depends(track_activity)])

log = logging.getLogger(__name__)


class OtpRequest(BaseModel):
    email: str = Field(..., max_length=254)


class OtpVerify(BaseModel):
    email: str = Field(..., max_length=254)
    code: str = Field(..., max_length=12)
    preferred_name: str = Field(default="", max_length=80)


class VerifyResponse(BaseModel):
    # "signed_up" (new account) | "verified" (already this account) | "restored"
    status: str
    profile: ProfileView
    # For "restored": how much came back. The session itself is unchanged.
    merged: dict[str, int] | None = None


class ProfilePatch(BaseModel):
    preferred_name: str | None = Field(default=None, max_length=80)
    signup_prompt_dismissed: bool | None = None


def _view(repo, uid: str, profile: UserProfile | None) -> ProfileView:
    """The profile as the app sees it, with the caller's entitlements attached."""
    return ProfileView.of(profile, tier_for(repo, uid))


def _require_email(value: str) -> str:
    if not is_email(value):
        # Literal 422: the named constant was renamed in Starlette and the old
        # spelling now warns.
        raise HTTPException(status_code=422, detail="That doesn't look like an email address.")
    return normalize_email(value)


@router.post("/otp/request", status_code=status.HTTP_204_NO_CONTENT)
def request_otp(body: OtpRequest, user: CurrentUser = Depends(get_current_user)) -> None:
    """Email a one-time code to `email`."""
    email = _require_email(body.email)
    try:
        get_otp_service().request_code(get_repository(), email, requester_uid=user.uid)
    except OtpError as exc:
        raise HTTPException(status_code=status.HTTP_429_TOO_MANY_REQUESTS, detail=str(exc)) from exc


@router.post("/otp/verify", response_model=VerifyResponse)
def verify_otp(body: OtpVerify, user: CurrentUser = Depends(get_current_user)) -> VerifyResponse:
    email = _require_email(body.email)
    repo = get_repository()

    try:
        challenge = get_otp_service().verify_code(repo, email, body.code)
    except OtpError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc

    # The same client must both ask for the code and present it. Without this a
    # code intercepted from someone else's inbox could be redeemed by any caller.
    if challenge.requester_uid and challenge.requester_uid != user.uid:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="That code was requested on another device. Ask for a new one here.",
        )

    now = datetime.now(timezone.utc)
    account_uid = repo.uid_for_email(email)

    # --- Signup, or re-verifying the account you're already signed into -----
    # Both reuse the caller's uid, so nothing moves and no token is needed.
    if account_uid is None or account_uid == user.uid:
        profile = repo.get_profile(user.uid) or UserProfile()
        if body.preferred_name.strip():
            profile.preferred_name = body.preferred_name.strip()
        profile.email = email
        profile.email_verified = True
        profile.updated_at = now
        repo.save_profile(user.uid, profile)
        repo.set_email_index(email, user.uid)
        _sync_stats_quietly(repo, user.uid, profile)
        if account_uid is None:
            # Only a genuinely new account counts as a signup. "verified" and
            # "restored" are existing accounts, and counting them would make
            # every reinstall and account switch look like growth.
            _bump_daily_quietly(repo, now, "email_signups")
        return VerifyResponse(
            status="signed_up" if account_uid is None else "verified",
            profile=_view(repo, user.uid, profile),
        )

    # --- Restore after a reinstall -----------------------------------------
    # The caller is a fresh anonymous identity; the account is whatever the
    # verified email points at. Both uids are derived server-side.
    #
    # The account is moved onto the caller rather than the caller being switched
    # to the account. That keeps the app's existing Firebase session — no custom
    # token to mint, no re-authentication, and identical behaviour locally and in
    # the cloud. It rewrites more documents (the whole account rather than the
    # handful recorded since reinstalling), which is a fine trade for something
    # that happens once per reinstall.
    account_profile = repo.get_profile(account_uid)
    account_settings = repo.get_settings_doc(account_uid)

    merged = repo.merge_user(account_uid, user.uid)

    # The account's own settings and name win over the throwaway's defaults.
    repo.save_settings_doc(user.uid, account_settings)
    profile = account_profile or UserProfile(email=email)
    if body.preferred_name.strip():
        profile.preferred_name = body.preferred_name.strip()
    profile.email = email
    profile.email_verified = True
    profile.updated_at = now
    repo.save_profile(user.uid, profile)
    # The address now points at the live session.
    repo.set_email_index(email, user.uid)
    _sync_stats_quietly(repo, user.uid, profile)

    log.info("restored %s for %s onto the current session", merged, email)
    return VerifyResponse(
        status="restored", profile=_view(repo, user.uid, profile), merged=merged
    )


@profile_router.get("", response_model=ProfileView)
def get_profile(user: CurrentUser = Depends(get_current_user)) -> ProfileView:
    repo = get_repository()
    return _view(repo, user.uid, repo.get_profile(user.uid))


@profile_router.patch("", response_model=ProfileView)
def patch_profile(
    body: ProfilePatch,
    user: CurrentUser = Depends(get_current_user),
) -> ProfileView:
    """Edit the parts of a profile the user controls directly.

    Email is deliberately not editable here — changing it goes through the OTP
    flow, which is what proves the new address is theirs.
    """
    repo = get_repository()
    profile = repo.get_profile(user.uid) or UserProfile()
    if body.preferred_name is not None:
        profile.preferred_name = body.preferred_name.strip()
    if body.signup_prompt_dismissed is not None:
        profile.signup_prompt_dismissed = body.signup_prompt_dismissed
    profile.updated_at = datetime.now(timezone.utc)
    repo.save_profile(user.uid, profile)
    _sync_stats_quietly(repo, user.uid, profile)
    return _view(repo, user.uid, profile)


def _sync_stats_quietly(repo, uid: str, profile: UserProfile) -> None:
    """Denormalize the profile onto the admin-facing record.

    Copied rather than joined so listing users costs one read per row. Best
    effort: the profile itself is already saved, and a stale admin column is not
    worth failing the user's request over.
    """
    try:
        repo.sync_user_identity(
            uid, profile.preferred_name, profile.email, profile.email_verified
        )
    except Exception:  # pragma: no cover - bookkeeping only
        log.exception("failed to sync identity for uid %s", uid)


def _bump_daily_quietly(repo, now: datetime, field: str) -> None:
    try:
        repo.bump_daily(now.date(), field)
    except Exception:  # pragma: no cover - bookkeeping only
        log.exception("failed to bump daily %s", field)
