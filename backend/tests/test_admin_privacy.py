"""The admin console must never expose the content of anyone's memories.

This is the file that keeps that true. The product's whole proposition is a
private voice journal; an operator tool that displays strangers' recordings
would undo it, and would be indefensible if the admin credentials ever leaked.

Two layers of guard, deliberately:

1. A behavioural check — record a known phrase, then assert it appears in no
   admin response body.
2. A structural check — assert the response models have no field that could
   carry content, so *adding* one fails here rather than leaking silently.

The second matters more. The first only covers the endpoints listed below; the
second covers every endpoint that will ever use these models.
"""

from app.models.admin import AdminRecordingRow, AdminUserDetail, AdminUserRow
from tests.conftest import admin_auth, auth

SECRET = "the pomegranate tree behind Amma's house in Madurai"

# Everything an admin can read. Kept in one place so a new endpoint is a
# one-line addition rather than an untested gap.
READ_PATHS = [
    "/admin/overview",
    "/admin/users",
    "/admin/users/count",
    "/admin/users/alice",
    "/admin/devices",
    "/admin/feedback",
    "/admin/audit",
    "/admin/recordings/failed",
    "/admin/metrics/timeseries?metric=recordings",
    "/admin/metrics/duration-histogram",
]

# Every field on `Recording` that is, or is derived from, what the user said.
# `title`, `people` and `places` are not innocuous metadata: they are
# model-generated descriptions of the content — the names of a user's family and
# the places they live.
CONTENT_FIELDS = {
    "transcript",
    "transcript_en",
    "summary",
    "title",
    "tags",
    "people",
    "places",
    "mood",
    "text",
    "embedding",
    "chunks",
    "audio_url",
    "audio_path",
}


def _seed(client, make_recording):
    make_recording("alice", SECRET)
    client.get("/recordings", headers=auth("alice"))


def test_no_admin_response_contains_transcript_text(client, make_recording):
    _seed(client, make_recording)

    # Sanity: the user really can see their own transcript, so a passing
    # assertion below means the admin surface excludes it — not that the
    # transcript was never stored.
    own = client.get("/recordings", headers=auth("alice"))
    assert SECRET in own.text

    for path in READ_PATHS:
        r = client.get(path, headers=admin_auth())
        assert r.status_code == 200, f"{path} -> {r.status_code} {r.text[:200]}"
        assert SECRET not in r.text, f"{path} leaked transcript content"


def test_admin_user_detail_exposes_metadata_but_not_content(client, make_recording):
    _seed(client, make_recording)

    body = client.get("/admin/users/alice", headers=admin_auth()).json()
    recordings = body["recent_recordings"]
    assert len(recordings) == 1

    # Useful operational metadata is present...
    assert recordings[0]["duration_sec"] == 5.0
    assert recordings[0]["status"] == "indexed"
    assert recordings[0]["language"] == "en"
    # ...and nothing describing what was said.
    assert not CONTENT_FIELDS & set(recordings[0])


def test_admin_detail_has_no_playable_audio(client, make_recording):
    _seed(client, make_recording)
    body = client.get("/admin/users/alice", headers=admin_auth()).text
    assert "audio_url" not in body
    assert "gs://" not in body


def test_admin_models_have_no_content_fields():
    """Structural guard.

    If someone later adds `title` to `AdminRecordingRow` because a dashboard
    column would look nice, this fails immediately — rather than quietly
    shipping a tool that reads people's memories.
    """
    for model in (AdminRecordingRow, AdminUserRow, AdminUserDetail):
        leaked = CONTENT_FIELDS & set(model.model_fields)
        assert not leaked, f"{model.__name__} exposes {leaked}"


def test_feedback_text_is_deliberately_visible(client):
    """The one exception, and it is a consent argument rather than an oversight:
    the user typed this into a "report a problem" box so a human would read it."""
    client.post(
        "/feedback",
        json={"kind": "problem", "message": "recording stops after 10s", "diagnostics": "stack"},
        headers=auth("alice"),
    )
    body = client.get("/admin/feedback", headers=admin_auth()).json()
    assert body["items"][0]["message"] == "recording stops after 10s"
    assert body["items"][0]["diagnostics"] == "stack"
