"""Authentication: turn a Firebase ID token into a ``CurrentUser``.

In real mode the bearer token is verified with the Firebase Admin SDK. In mock mode the token is
treated as the uid (or an ``X-Debug-Uid`` header is honored) so the API is exercisable in tests and
local dev without real credentials.
"""

from __future__ import annotations

from dataclasses import dataclass

from fastapi import Depends, Header, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.core.config import Settings, get_settings

_bearer = HTTPBearer(auto_error=False)


@dataclass(frozen=True)
class CurrentUser:
    uid: str
    email: str | None = None
    # Both are needed to decide admin access and were previously discarded.
    # `email_verified` is the security-critical one: Firebase's email/password
    # provider lets anyone *claim* an address, so an unverified email proves
    # nothing about who is holding the token.
    email_verified: bool = False
    provider: str = ""


def _verify_firebase_token(token: str, settings: Settings) -> CurrentUser:
    try:
        import firebase_admin
        from firebase_admin import auth as fb_auth
    except ImportError as exc:  # pragma: no cover - only in real mode
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="firebase-admin not installed; install the [gcp] extra.",
        ) from exc

    if not firebase_admin._apps:  # pragma: no cover - init once in real mode
        firebase_admin.initialize_app(options={"projectId": settings.firebase_project})

    try:
        decoded = fb_auth.verify_id_token(token, check_revoked=True)
    except Exception as exc:  # pragma: no cover - real verification path
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid ID token"
        ) from exc
    firebase = decoded.get("firebase") or {}
    return CurrentUser(
        uid=decoded["uid"],
        email=decoded.get("email"),
        email_verified=bool(decoded.get("email_verified")),
        provider=str(firebase.get("sign_in_provider") or ""),
    )


async def get_current_user(
    creds: HTTPAuthorizationCredentials | None = Depends(_bearer),
    x_debug_uid: str | None = Header(default=None),
    settings: Settings = Depends(get_settings),
) -> CurrentUser:
    if settings.effective_mock:
        uid = x_debug_uid or (creds.credentials if creds else None)
        if not uid:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Provide a bearer token (used as uid in mock mode) or X-Debug-Uid.",
            )
        return CurrentUser(
            uid=uid, email=f"{uid}@mock.local", email_verified=True, provider="mock"
        )

    if not creds:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing bearer token"
        )
    return _verify_firebase_token(creds.credentials, settings)


def _is_admin(user: CurrentUser, settings: Settings) -> bool:
    """Allowlist membership, by uid or by *verified* email.

    An allowlist rather than a Firebase custom claim: claims need an out-of-band
    script to set and survive in an issued token until it expires, and
    `_verify_firebase_token` never runs in mock mode — so a claim-based check
    would be untestable here. This runs the identical code path in both modes.
    """
    if user.uid in settings.admin_uid_set:
        return True
    # Anonymous users have no email at all, which is why the app population
    # cannot match this list even in principle.
    if not user.email or not user.email_verified:
        return False
    return user.email.strip().lower() in settings.admin_email_set


async def require_admin(
    user: CurrentUser = Depends(get_current_user),
    settings: Settings = Depends(get_settings),
) -> CurrentUser:
    """Gate for `/admin`. An empty allowlist denies everyone — fail closed."""
    if not _is_admin(user, settings):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="Admin access required"
        )
    return user
