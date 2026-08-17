"""VoiceIQ FastAPI application.

"VoiceIQ" is the internal/service name throughout the backend and infrastructure.
The product users see is called MemoriesIQ; the split is deliberate.
"""

from __future__ import annotations

import logging

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.api.routers import (
    account,
    admin,
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
    uploads,
)
from app.api.routers import (
    settings as settings_router,
)
from app.core.config import get_settings

log = logging.getLogger(__name__)


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(
        title="VoiceIQ API",
        version="0.1.0",
        summary="Record life moments by voice; ask an AI to recall them.",
    )

    # Turn an unhandled exception into a JSON 500 *inside* the CORS layer.
    #
    # Starlette's own error middleware sits OUTSIDE CORSMiddleware, so a crash
    # produces a bare 500 with no `Access-Control-Allow-Origin` header. A browser
    # cannot read such a response and reports it as "Failed to fetch" — which
    # tells the operator nothing and hides the real cause. Registered before the
    # CORS middleware below so that CORS ends up wrapping it.
    @app.middleware("http")
    async def json_errors(request, call_next):
        try:
            return await call_next(request)
        except Exception:
            log.exception("unhandled error on %s %s", request.method, request.url.path)
            return JSONResponse(
                status_code=500,
                content={"detail": "Internal server error. Check the service logs."},
            )

    # Config-driven, defaulting to "*" for local dev. Note what this does and
    # does not buy: auth here is a bearer token, never a cookie, so a hostile
    # site cannot make an authenticated request just because its origin is
    # allowed — it has no token to send. CORS is defence in depth; `require_admin`
    # is the actual boundary for /admin. The native app ignores CORS entirely,
    # so tightening this costs mobile nothing.
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origin_list,
        allow_methods=["*"],
        # Enumerated rather than "*", because the device headers below are
        # preflighted by browsers and would otherwise depend on the wildcard.
        allow_headers=[
            "Authorization",
            "Content-Type",
            "X-Debug-Uid",
            "X-Install-Id",
            "X-Platform",
            "X-App-Version",
        ],
        max_age=600,
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
    # Always mounted, so the OpenAPI surface is the same everywhere. The guard
    # is a router-level dependency and an empty allowlist denies everyone, so
    # mounting it is not the same as exposing it.
    app.include_router(admin.router)
    if not settings.admin_configured:
        log.warning(
            "No VOICEIQ_ADMIN_UIDS or VOICEIQ_ADMIN_EMAILS set; /admin will reject everyone."
        )

    # Testing/dev helpers only when running with in-memory fakes.
    if settings.effective_mock:
        app.include_router(dev.router)
        app.include_router(mock_storage.router)

    return app


app = create_app()
