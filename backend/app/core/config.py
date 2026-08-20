"""Application settings.

Loaded from environment (prefix ``VOICEIQ_``) and, in real mode, Secret Manager. When no GCP
project is configured, ``mock`` defaults to True so the whole service runs in-memory.

Two config files, one per profile, in ``backend/config``:

``local.env``
    Local development, the Android emulator, and the test suite. Committed, and
    holds nothing secret.
``production.env``
    Real GCP, real Gemini, and the Azure credential. **Gitignored** — this
    repository is public — with ``production.env.example`` committed in its place.

``local.env`` always loads first as the base and the profile layers on top, so a
profile only states what genuinely differs. The profile is chosen by
``VOICEIQ_ENV``, which is *unset* by default: an unconfigured process gets the
offline, credential-free profile rather than reaching for real infrastructure.

Neither file reaches Cloud Run — the Dockerfile copies only ``pyproject.toml``
and ``app/``. Production is configured by the env vars Terraform sets on the
service, and Terraform reads the model ids out of ``production.env`` so that the
file a developer edits is the one production runs.
"""

from __future__ import annotations

import os
from functools import lru_cache
from pathlib import Path

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict

_CONFIG_DIR = Path(__file__).resolve().parents[2] / "config"
_DEFAULT_PROFILE = "local"


def _env_files() -> tuple[Path, Path]:
    """The base profile and the selected one, in the order pydantic applies them."""
    profile = (os.getenv("VOICEIQ_ENV") or _DEFAULT_PROFILE).strip() or _DEFAULT_PROFILE
    return (_CONFIG_DIR / f"{_DEFAULT_PROFILE}.env", _CONFIG_DIR / f"{profile}.env")


def _split(value: str) -> list[str]:
    """Parse a comma-separated setting, dropping blanks and surrounding space."""
    return [part.strip() for part in value.split(",") if part.strip()]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="VOICEIQ_", env_file=_env_files(), extra="ignore"
    )

    # Mode ------------------------------------------------------------------
    mock: bool = Field(default=True, description="Run with in-memory fakes for all cloud services.")

    # Google Cloud / Firebase ----------------------------------------------
    gcp_project: str = ""
    gcp_region: str = "us-central1"
    firebase_project: str = ""
    audio_bucket: str = "voiceiq-audio"
    kms_key: str = ""
    pubsub_ingest_topic: str = "voiceiq-ingest"

    # Model slots (independently swappable) --------------------------------
    # Concrete Vertex ids, not "-latest" aliases: those exist on the Gemini
    # Developer API but are **not published on Vertex** — the publisher list for
    # this project in us-central1 has 128 models and not one ends in "latest",
    # so an alias here fails the call outright. Override per environment with
    # VOICEIQ_MODEL_* (backend/.env locally, Cloud Run env in production); these
    # defaults are what the app runs on when nothing overrides them.
    model_reasoning: str = "gemini-2.5-flash"
    # Native-audio dialog: the model generates the waveform itself, with its own
    # prosody, rather than producing text for a synthesizer to read.
    model_live: str = "gemini-live-2.5-flash-native-audio"
    model_embedding: str = "text-multilingual-embedding-002"
    embedding_dim: int = 256

    # Email (Azure Communication Services) ----------------------------------
    # Connection string looks like "endpoint=https://x.communication.azure.com/;accesskey=..."
    # Keep it out of git: backend/.env locally, Secret Manager on Cloud Run.
    acs_connection_string: str = ""
    acs_sender: str = ""
    # Mock mode normally suppresses sending. Set this to send for real anyway —
    # the only way to prove delivery works without switching the whole service
    # over to real GCP. Never enable it in tests.
    acs_force_send: bool = False

    # Sign-in codes ---------------------------------------------------------
    otp_ttl_seconds: int = 600
    otp_max_attempts: int = 5
    otp_resend_cooldown_seconds: int = 60
    otp_code_length: int = 6

    # Admin console ---------------------------------------------------------
    # Comma-separated, NOT list[str]: pydantic-settings parses a list-typed env
    # var as JSON, so `VOICEIQ_ADMIN_UIDS=a,b` would fail validation and the
    # Terraform env block would have to spell it `["a","b"]`.
    admin_uids: str = ""
    admin_emails: str = ""

    # How long an instance may skip re-writing a user's activity record. Day
    # granularity in practice; this only bounds the in-process cache.
    activity_throttle_seconds: int = 900

    # CORS. "*" is the dev default; production names the console's origin.
    cors_origins: str = "*"

    # Entitlements ----------------------------------------------------------
    # How long a typed memory may be, by tier. Settings rather than constants so
    # the cap can be retuned from the Cloud Run env without a code deploy — the
    # right knob to have while we are still learning what people actually type.
    text_max_chars_free: int = 1000
    text_max_chars_premium: int = 10000

    # How many journals a tier may keep. Free is a ceiling rather than a wall so
    # people learn what journals are for before they hit it; going over the free
    # limit (by lapsing from premium) never deletes anything, it only blocks
    # creating more.
    journals_max_free: int = 2
    journals_max_premium: int = 20

    # How many *voice* memories a tier may create per calendar month. Typed
    # memories are deliberately not metered: the cap exists because transcribing
    # and enriching audio costs real money per minute, and typing costs nothing —
    # the lever on typed memories is `text_max_chars_*` above.
    recordings_per_month_free: int = 10
    recordings_per_month_premium: int = 100

    # How long one recording may be. The app stops the recorder at this number;
    # the API rejects anything over it, which is the backstop for a client that
    # did not.
    recording_max_seconds_free: int = 60
    recording_max_seconds_premium: int = 600

    # How long one spoken conversation may last before the server hangs up.
    # Per conversation, not per month: it bounds a single open Gemini Live socket,
    # which is the thing that costs money while it is held.
    voice_session_max_seconds_free: int = 600
    voice_session_max_seconds_premium: int = 3600

    # Behavior --------------------------------------------------------------
    signed_url_ttl_seconds: int = 900
    rag_top_k: int = 6
    default_answer_language: str = "auto"

    @property
    def effective_mock(self) -> bool:
        """Force mock when no project is configured, regardless of the flag."""
        return self.mock or not self.gcp_project

    @property
    def admin_uid_set(self) -> frozenset[str]:
        return frozenset(_split(self.admin_uids))

    @property
    def admin_email_set(self) -> frozenset[str]:
        """Lowercased, so the allowlist matches however the address is typed."""
        return frozenset(e.lower() for e in _split(self.admin_emails))

    @property
    def admin_configured(self) -> bool:
        return bool(self.admin_uid_set or self.admin_email_set)

    @property
    def cors_origin_list(self) -> list[str]:
        return _split(self.cors_origins) or ["*"]

    @property
    def email_configured(self) -> bool:
        return bool(self.acs_connection_string and self.acs_sender)


@lru_cache
def get_settings() -> Settings:
    return Settings()
