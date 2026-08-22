"""Account ids, session ids, and the credential a device signs in with.

The account id is issued here once and never changes again — which is the whole
point of this module. Identity used to *be* the phone: a per-install anonymous
uid, so signing in on a second device had to drag the entire account across to
it and leave the first one empty. A permanent id lets any number of devices hold
the same account by presenting a token minted for that id, and lets the account
outlive every one of them.

Mock mode has no Firebase, and the API there treats the bearer token as the uid
(see ``core.security``). So the "token" a mock login hands back is the uid
itself: the same flow, the same endpoints, the same client code, no credentials.
"""

from __future__ import annotations

import uuid

from app.core.config import Settings, get_settings


def new_account_uid() -> str:
    """A fresh, permanent account id.

    Prefixed so an account id is recognisable at a glance in a log or a Firestore
    console — the old anonymous uids are still scattered through both.
    """
    return f"usr_{uuid.uuid4().hex}"


def new_session_id() -> str:
    return f"ses_{uuid.uuid4().hex}"


def new_ticket() -> str:
    return f"tkt_{uuid.uuid4().hex}"


def mint_token(uid: str, settings: Settings | None = None) -> str:
    """A credential the app exchanges for a signed-in Firebase session.

    Real mode mints a Firebase custom token for `uid`; the app calls
    ``signInWithCustomToken`` and every device that logs into one email ends up
    authenticated as the same account. No key file is involved — the Cloud Run
    service account signs through the IAM API, the same mechanism the signed
    upload URLs already use.
    """
    settings = settings or get_settings()
    if settings.effective_mock:
        return uid
    return _firebase_custom_token(uid, settings)  # pragma: no cover - real path


def _firebase_custom_token(uid: str, settings: Settings) -> str:  # pragma: no cover
    import firebase_admin
    from firebase_admin import auth as fb_auth

    if not firebase_admin._apps:
        firebase_admin.initialize_app(options={"projectId": settings.firebase_project})
    token = fb_auth.create_custom_token(uid)
    # The SDK returns bytes; the API returns JSON.
    return token.decode("utf-8") if isinstance(token, bytes) else str(token)
