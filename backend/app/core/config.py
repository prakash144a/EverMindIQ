"""Application settings.

Loaded from environment (prefix ``VOICEIQ_``) and, in real mode, Secret Manager. When no GCP
project is configured, ``mock`` defaults to True so the whole service runs in-memory.
"""

from __future__ import annotations

from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


def _split(value: str) -> list[str]:
    """Parse a comma-separated setting, dropping blanks and surrounding space."""
    return [part.strip() for part in value.split(",") if part.strip()]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="VOICEIQ_", env_file=".env", extra="ignore"
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
    model_reasoning: str = "gemini-flash-latest"
    model_live: str = "gemini-live-latest"
    model_embedding: str = "text-multilingual-embedding-latest"
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
