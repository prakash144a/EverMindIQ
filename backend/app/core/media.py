"""Audio container/MIME mapping.

One table, three consumers: the object name we write to GCS (`storage.py`), the
MIME type we hand Gemini for transcription (`gemini.py`), and the `Content-Type`
we serve for in-app playback (`recordings.py`). Keeping them in one place is the
point — they were previously hardcoded to m4a in all three, so a web client's
`audio/webm` upload was stored as `.m4a` and served back as `audio/mp4`.
"""

from __future__ import annotations

DEFAULT_EXT = ".m4a"
DEFAULT_CONTENT_TYPE = "audio/mp4"

# What the client says it is uploading -> the extension we store it under.
_EXT_BY_CONTENT_TYPE = {
    "audio/m4a": ".m4a",
    "audio/x-m4a": ".m4a",
    "audio/mp4": ".m4a",
    "audio/aac": ".m4a",
    "audio/webm": ".webm",
    "audio/ogg": ".ogg",
    "audio/opus": ".ogg",
    "audio/wav": ".wav",
    "audio/x-wav": ".wav",
    "audio/mpeg": ".mp3",
    "audio/flac": ".flac",
}

# Extension -> the canonical MIME type. Deliberately IANA/Vertex names: the
# non-standard "audio/m4a" a client may send is normalized to "audio/mp4" here,
# which is what Gemini's audio input documents.
_CONTENT_TYPE_BY_EXT = {
    ".m4a": "audio/mp4",
    ".webm": "audio/webm",
    ".ogg": "audio/ogg",
    ".wav": "audio/wav",
    ".mp3": "audio/mpeg",
    ".flac": "audio/flac",
}


def ext_for_content_type(content_type: str) -> str:
    """Extension to store an upload under. Unknown types fall back to m4a (the mobile default)."""
    base = (content_type or "").split(";", 1)[0].strip().lower()
    return _EXT_BY_CONTENT_TYPE.get(base, DEFAULT_EXT)


def content_type_for_path(path: str) -> str:
    """Canonical MIME type for a stored object, derived from its extension."""
    lowered = (path or "").lower()
    for ext, ct in _CONTENT_TYPE_BY_EXT.items():
        if lowered.endswith(ext):
            return ct
    return DEFAULT_CONTENT_TYPE
