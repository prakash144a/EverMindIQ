"""Application settings.

Loaded from environment (prefix ``VOICEIQ_``) and, in real mode, Secret Manager. When no GCP
project is configured, ``mock`` defaults to True so the whole service runs in-memory.
"""

from __future__ import annotations

from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


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

    # Behavior --------------------------------------------------------------
    signed_url_ttl_seconds: int = 900
    rag_top_k: int = 6
    default_answer_language: str = "auto"

    @property
    def effective_mock(self) -> bool:
        """Force mock when no project is configured, regardless of the flag."""
        return self.mock or not self.gcp_project


@lru_cache
def get_settings() -> Settings:
    return Settings()
