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
    return CurrentUser(uid=decoded["uid"], email=decoded.get("email"))


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
        return CurrentUser(uid=uid, email=f"{uid}@mock.local")

    if not creds:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing bearer token"
        )
    return _verify_firebase_token(creds.credentials, settings)
