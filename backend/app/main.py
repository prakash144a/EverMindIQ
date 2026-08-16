"""VoiceIQ FastAPI application."""

from __future__ import annotations

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.core.config import get_settings
from app.api.routers import (
    account,
    auth,
    chat,
    dev,
    feedback,
    insights,
    internal,
    live,
    memories,
    mock_storage,
    recordings,
    settings as settings_router,
    uploads,
)


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(
        title="VoiceIQ API",
        version="0.1.0",
        summary="Record life moments by voice; ask an AI to recall them.",
    )

    # CORS is broad in dev; tighten to the app's origins in production.
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_methods=["*"],
        allow_headers=["*"],
    )

    # NB: use /health, not /healthz — Google Front End intercepts the exact
    # path /healthz on *.run.app and returns its own 404 before the container.
    @app.get("/health", tags=["health"])
    def health() -> dict:
        return {"status": "ok", "mock": settings.effective_mock}

    app.include_router(uploads.router)
    app.include_router(recordings.router)
    app.include_router(chat.router)
    app.include_router(insights.router)
    app.include_router(memories.router)
    app.include_router(settings_router.router)
    app.include_router(account.router)
    app.include_router(auth.router)
    app.include_router(auth.profile_router)
    app.include_router(feedback.router)
    app.include_router(internal.router)
    app.include_router(live.router)

    # Testing/dev helpers only when running with in-memory fakes.
    if settings.effective_mock:
        app.include_router(dev.router)
        app.include_router(mock_storage.router)

    return app


app = create_app()
