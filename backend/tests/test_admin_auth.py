"""Who may reach /admin.

The console exposes account data across every user, so this is the one gate
that matters. The allowlist runs the identical code path in mock and real mode,
which is exactly why it was chosen over Firebase custom claims — those are set
out of band and `_verify_firebase_token` never runs here, so a claim-based check
would be untestable.
"""

import pytest

from app.core.config import Settings, get_settings
from app.core.security import CurrentUser, _is_admin
from app.main import create_app
from tests.conftest import ADMIN_UID, admin_auth, auth

# One of each shape: a collection, a detail route, a mutation, a chart.
ADMIN_PATHS = [
    "/admin/me",
    "/admin/overview",
    "/admin/users",
    "/admin/users/count",
    "/admin/devices",
    "/admin/feedback",
    "/admin/audit",
    "/admin/recordings/failed",
    "/admin/metrics/timeseries?metric=recordings",
]


def test_admin_endpoints_reject_an_anonymous_caller(client):
    for path in ADMIN_PATHS:
        assert client.get(path).status_code == 401, path


@pytest.mark.parametrize("path", ADMIN_PATHS)
def test_ordinary_users_are_forbidden(client, path):
    assert client.get(path, headers=auth("alice")).status_code == 403


def test_allowlisted_admin_is_allowed(client):
    r = client.get("/admin/me", headers=admin_auth())
    assert r.status_code == 200
    assert r.json()["uid"] == ADMIN_UID
    assert r.json()["is_admin"] is True


def test_a_non_admin_cannot_mutate_a_tier(client):
    r = client.patch("/admin/users/bob", json={"tier": "premium"}, headers=auth("alice"))
    assert r.status_code == 403


def test_an_empty_allowlist_denies_even_the_admin():
    """Fail closed: a deploy that forgets to configure admins admits nobody."""
    app = create_app()
    app.dependency_overrides[get_settings] = lambda: Settings(
        mock=True, admin_uids="", admin_emails=""
    )
    from fastapi.testclient import TestClient

    with TestClient(app) as unconfigured:
        assert unconfigured.get("/admin/overview", headers=admin_auth()).status_code == 403


# -- _is_admin directly -------------------------------------------------
#
# The email arm cannot be reached through the mock HTTP path (mock mode
# synthesizes uid@mock.local), so it is tested against the function.


def test_email_allowlist_requires_a_verified_email():
    """The security-critical case.

    Firebase's email/password provider issues a token for any address the caller
    types, with `email_verified: false`. Without this check, allowlisting an
    address would let anyone who registers it become an admin.
    """
    settings = Settings(mock=True, admin_uids="", admin_emails="boss@example.com")
    unverified = CurrentUser(uid="x", email="boss@example.com", email_verified=False)
    verified = CurrentUser(uid="x", email="boss@example.com", email_verified=True)

    assert not _is_admin(unverified, settings)
    assert _is_admin(verified, settings)


def test_email_allowlist_ignores_case_and_padding():
    settings = Settings(mock=True, admin_uids="", admin_emails=" Boss@Example.COM , other@x.com ")
    user = CurrentUser(uid="x", email="BOSS@example.com", email_verified=True)
    assert _is_admin(user, settings)


def test_an_anonymous_user_can_never_be_admin():
    """Every app user today is a Firebase anonymous identity with no email
    claim at all, so the app population cannot match an email allowlist."""
    settings = Settings(mock=True, admin_uids="", admin_emails="boss@example.com")
    assert not _is_admin(CurrentUser(uid="anon-uid", email=None), settings)


def test_a_comma_separated_env_value_parses():
    """Regression guard: a `list[str]` setting would be parsed as JSON by
    pydantic-settings, so `a,b` would fail validation entirely."""
    settings = Settings(mock=True, admin_uids="a, b ,,c")
    assert settings.admin_uid_set == frozenset({"a", "b", "c"})
    assert settings.admin_configured
