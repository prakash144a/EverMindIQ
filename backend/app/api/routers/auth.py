"""Logging in, logging out, and the devices that may hold an account.

An account may be open in two places at once — one phone and one browser. Those
are its *surfaces*, and each holds its own session: recording a memory on a
laptop does not sign the phone in someone's pocket out, and the memory shows up
on both because neither device is where the memories live. Within a surface the
rule is still one at a time, so a second phone displaces the first.

Login is a code to an inbox, in two steps:

1. ``POST /auth/otp/request`` emails a code. ``POST /auth/otp/verify`` checks it
   and hands back a short-lived **ticket** — plus, if another device is already
   signed in *on this surface*, a description of it.
2. ``POST /auth/session`` spends the ticket for a Firebase custom token and a
   session id. If another device holds that surface it refuses with 409 until
   the caller says ``takeover``.

The split exists for that refusal. A person signing in on a new phone has to be
able to see "this account is open on an Android phone" and *decide*, and by the
time we know that, their code is already spent — so the ticket carries the
verified state across the question.

The uid is never taken from the request. It is issued once per email, here, and
never changes again: two devices signing into one address are the same account
rather than two, and nothing has to be moved between them. Anything the caller
sends about who they are is ignored; the address is proven by the code, and the
device by the install id that asked for it.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, Header, HTTPException, status
from pydantic import BaseModel, Field

from app.core.activity import track_activity
from app.core.entitlements import tier_and_voice_usage
from app.core.security import CurrentUser, get_current_user, require_live_session
from app.models.user import (
    DeviceSession,
    LoginTicket,
    ProfileView,
    UserProfile,
    is_email,
    normalize_email,
    surface_for,
)
from app.services.firestore import get_repository
from app.services.identity import mint_token, new_account_uid, new_session_id, new_ticket
from app.services.otp import OtpError, get_otp_service

router = APIRouter(prefix="/auth", tags=["auth"])
profile_router = APIRouter(prefix="/profile", tags=["auth"], dependencies=[Depends(track_activity)])

log = logging.getLogger(__name__)

# How long a verified code stays redeemable. Long enough to read a question and
# answer it, short enough that a ticket left in a log is worthless by the time
# anyone reads it.
TICKET_TTL = timedelta(minutes=10)


class OtpRequest(BaseModel):
    email: str = Field(..., max_length=254)


class OtpVerify(BaseModel):
    email: str = Field(..., max_length=254)
    code: str = Field(..., max_length=12)
    # Older app builds asked for the name on the first screen and send it here.
    # Current ones ask after the code, only when `needs_name`, and send it with
    # the claim instead. Kept so an installed app does not break.
    preferred_name: str = Field(default="", max_length=80)


class SessionView(BaseModel):
    """A device holding an account, as the person being asked about it sees it.

    Says when it *signed in*, not when it was last used. Tracking the latter
    would mean a write on every request to answer a question nobody asked, and
    "signed in on Tuesday at 4pm" is the fact someone actually needs to
    recognise the device as theirs.
    """

    device: str  # "an Android phone"
    platform: str = ""
    app_version: str = ""
    signed_in_at: datetime

    @classmethod
    def of(cls, session: DeviceSession) -> SessionView:
        return cls(
            device=session.label,
            platform=session.platform,
            app_version=session.app_version,
            signed_in_at=session.signed_in_at,
        )


class VerifyResponse(BaseModel):
    # "signed_up" (the address had no account) | "signed_in" (it did)
    status: str
    ticket: str
    # Set when another device holds this account: the caller must confirm the
    # takeover before a session is issued. Null means nothing is in the way.
    active_session: SessionView | None = None
    # The account has no name to greet its owner by, so the app should ask for
    # one before claiming the session. True for a new address, and for one whose
    # owner walked away before answering last time. An account that has a name
    # is never asked again at the door — that is what the profile screen is for.
    needs_name: bool = False


class ClaimRequest(BaseModel):
    ticket: str = Field(..., max_length=80)
    # Deliberately explicit and defaulting to false: signing someone out is not
    # something to do as a side effect of a client forgetting a field.
    takeover: bool = False
    # What to call the person, asked after the code when the account has no name
    # yet. Ignored for an account that already has one: signing in is not a way
    # to rename yourself, and a stale form field must not be able to do it.
    preferred_name: str = Field(default="", max_length=80)


class ClaimResponse(BaseModel):
    uid: str
    # Exchanged for a Firebase session by the app; in mock mode it is the uid.
    token: str
    session_id: str
    profile: ProfileView


class ProfilePatch(BaseModel):
    preferred_name: str | None = Field(default=None, max_length=80)
    signup_prompt_dismissed: bool | None = None


def _view(repo, uid: str, profile: UserProfile | None) -> ProfileView:
    """The profile as the app sees it, with the caller's entitlements attached."""
    tier, voice_used = tier_and_voice_usage(repo, uid)
    return ProfileView.of(profile, tier, voice_used)


def _require_email(value: str) -> str:
    if not is_email(value):
        # Literal 422: the named constant was renamed in Starlette and the old
        # spelling now warns.
        raise HTTPException(status_code=422, detail="That doesn't look like an email address.")
    return normalize_email(value)


@router.post("/otp/request", status_code=status.HTTP_204_NO_CONTENT)
def request_otp(
    body: OtpRequest,
    x_install_id: str | None = Header(default=None),
) -> None:
    """Email a one-time code to `email`.

    Unauthenticated, necessarily: this is how someone with no session at all
    gets one. What stands in for a caller identity is the install id, which the
    verify step insists on seeing again.
    """
    email = _require_email(body.email)
    try:
        get_otp_service().request_code(
            get_repository(), email, requester_install_id=(x_install_id or "").strip()[:128]
        )
    except OtpError as exc:
        raise HTTPException(status_code=status.HTTP_429_TOO_MANY_REQUESTS, detail=str(exc)) from exc


@router.post("/otp/verify", response_model=VerifyResponse)
def verify_otp(
    body: OtpVerify,
    x_install_id: str | None = Header(default=None),
    x_platform: str | None = Header(default=None),
    x_app_version: str | None = Header(default=None),
) -> VerifyResponse:
    """Check a code, and report what stands between the caller and a session."""
    email = _require_email(body.email)
    repo = get_repository()
    install_id = (x_install_id or "").strip()[:128]

    try:
        challenge = get_otp_service().verify_code(repo, email, body.code)
    except OtpError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc

    # The device that asked must be the device that answers. Without this, a code
    # glimpsed in someone else's inbox could be redeemed from anywhere.
    if challenge.requester_install_id and challenge.requester_install_id != install_id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="That code was requested on another device. Ask for a new one here.",
        )

    now = datetime.now(timezone.utc)
    uid = repo.uid_for_email(email)
    is_new = uid is None
    if uid is None:
        uid = _create_account(repo, email, body.preferred_name, now)
    elif body.preferred_name.strip():
        profile = repo.get_profile(uid) or UserProfile(email=email, email_verified=True)
        profile.preferred_name = body.preferred_name.strip()
        profile.updated_at = now
        repo.save_profile(uid, profile)
        _sync_stats_quietly(repo, uid, profile)

    ticket = repo.save_login_ticket(
        LoginTicket(
            ticket=new_ticket(),
            uid=uid,
            email=email,
            expires_at=now + TICKET_TTL,
            created_at=now,
            install_id=install_id,
            platform=(x_platform or "").strip()[:64],
            app_version=(x_app_version or "").strip()[:64],
            is_new_account=is_new,
        )
    )

    # Only the caller's own surface can be in the way. A phone signed in on this
    # account is no obstacle to opening the web app, and asking about it would
    # invite someone to sign their own phone out for no reason.
    held = repo.get_session(uid, surface_for(x_platform or ""))
    profile = repo.get_profile(uid)
    return VerifyResponse(
        status="signed_up" if is_new else "signed_in",
        ticket=ticket.ticket,
        needs_name=not (profile and profile.preferred_name.strip()),
        # Its own device signing in again is not something to ask about.
        active_session=(
            SessionView.of(held) if held and held.install_id != install_id else None
        ),
    )


@router.post("/session", response_model=ClaimResponse)
def claim_session(body: ClaimRequest) -> ClaimResponse:
    """Spend a ticket for a session, taking the account over if asked to.

    Whoever was signed in is signed out by this — they find out on their next
    request, which is the only moment we can tell them anything at all.
    """
    repo = get_repository()
    ticket = repo.get_login_ticket(body.ticket)
    now = datetime.now(timezone.utc)
    if ticket is None or ticket.is_expired(now):
        if ticket is not None:
            repo.delete_login_ticket(ticket.ticket)
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="That sign-in has expired. Ask for a new code.",
        )

    # Contention is within a surface, never across one: the browser slot is the
    # only thing a browser can displace, and the mobile slot the only thing a
    # phone can.
    held = repo.get_session(ticket.uid, surface_for(ticket.platform))
    if held is not None and held.install_id != ticket.install_id and not body.takeover:
        # Not an error the app should show as one: it is a question, and the
        # answer comes back as the same call with `takeover` set.
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "code": "session_active",
                "message": "This account is signed in on another device.",
                "active_session": SessionView.of(held).model_dump(mode="json"),
            },
        )

    repo.delete_login_ticket(ticket.ticket)  # single use
    session = repo.save_session(
        ticket.uid,
        DeviceSession(
            session_id=new_session_id(),
            install_id=ticket.install_id,
            platform=ticket.platform,
            app_version=ticket.app_version,
            signed_in_at=now,
        ),
    )
    profile = _name_if_unnamed(repo, ticket, body.preferred_name, now)
    log.info("session opened for %s on %s", ticket.uid, session.platform or "unknown")
    return ClaimResponse(
        uid=ticket.uid,
        token=mint_token(ticket.uid),
        session_id=session.session_id,
        profile=_view(repo, ticket.uid, profile),
    )


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
def logout(
    user: CurrentUser = Depends(require_live_session),
    x_session_id: str | None = Header(default=None),
) -> None:
    """Hand this device back.

    The account keeps everything; what ends is this device's hold on it, so the
    next person to pick the phone up gets a login screen and their own memories
    rather than someone else's.

    Only the caller's own surface is released. Closing the browser tab must not
    sign the phone in your pocket out, so the slot to clear is found by the
    session id the caller presented rather than by the platform it claims — the
    header is the caller's own, and `require_live_session` has just proved the
    session id.
    """
    repo = get_repository()
    presented = (x_session_id or "").strip()
    for surface, held in repo.get_sessions(user.uid).items():
        if held.session_id == presented:
            repo.clear_session(user.uid, surface)
            return


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


def _name_if_unnamed(repo, ticket: LoginTicket, name: str, now: datetime) -> UserProfile | None:
    """Give the account the name asked for at sign-in, if it has none yet.

    Only ever fills a blank. The app asks this question when `verify` said the
    account had no name; an account that has one keeps it whatever the claim
    carries, and renaming goes through the profile.
    """
    profile = repo.get_profile(ticket.uid)
    name = name.strip()
    if not name or (profile and profile.preferred_name.strip()):
        return profile
    profile = profile or UserProfile(email=ticket.email, email_verified=True)
    profile.preferred_name = name
    profile.updated_at = now
    repo.save_profile(ticket.uid, profile)
    _sync_stats_quietly(repo, ticket.uid, profile)
    return profile


def _create_account(repo, email: str, preferred_name: str, now: datetime) -> str:
    """Issue an account for an address nobody has claimed yet."""
    uid = new_account_uid()
    profile = UserProfile(
        preferred_name=preferred_name.strip(),
        email=email,
        email_verified=True,
        created_at=now,
        updated_at=now,
    )
    repo.save_profile(uid, profile)
    repo.set_email_index(email, uid)
    repo.ensure_user_stats(uid)
    _sync_stats_quietly(repo, uid, profile)
    _bump_daily_quietly(repo, now, "email_signups")
    return uid


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
