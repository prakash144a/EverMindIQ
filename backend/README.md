# VoiceIQ Backend

FastAPI service: REST API + ingestion pipeline + RAG + Gemini Live proxy.

## Modes

- **Mock mode (default)** — everything runs in-memory (Firestore, GCS, Gemini all faked). No cloud
  credentials needed. This is what tests use and what powers local development.
- **Real mode** — set `VOICEIQ_MOCK=0` and `VOICEIQ_GCP_PROJECT`, install the `[gcp]` extra, and
  provide Application Default Credentials.

## Run locally

```bash
python -m venv .venv
source .venv/bin/activate            # Windows: .venv\Scripts\activate
pip install -e ".[dev]"
cp .env.example .env                 # defaults are fine for mock mode
uvicorn app.main:app --reload        # http://localhost:8000/docs
```

## Test

```bash
pip install -e ".[dev]"
pytest -q
```

The suite runs fully offline (mock mode) and covers: auth enforcement, signed-URL upload, the
record→transcribe→index→browse flow, RAG retrieval with citations, cross-user isolation, date
filtering, insights + caching, On-This-Day, the Live WebSocket, multilingual plumbing, and account
purge.

## Endpoints

| Method | Path                     | Purpose                                        |
|--------|--------------------------|------------------------------------------------|
| GET    | `/healthz`               | Liveness + mode.                               |
| POST   | `/uploads`               | Signed URL for direct audio upload.            |
| POST   | `/recordings`            | Register uploaded audio; triggers ingestion.   |
| GET    | `/recordings`            | List (optional `date_from`/`date_to`).         |
| GET    | `/recordings/{id}`       | Recording + signed audio URL.                  |
| DELETE | `/recordings/{id}`       | Delete a recording.                            |
| POST   | `/chat`                  | Text RAG over memories (answer + citations).   |
| POST   | `/insights`              | Range summary (day…lifetime…custom), cached.   |
| GET    | `/memories/on-this-day`  | Home slideshow feed.                           |
| GET/PUT| `/settings`              | User settings.                                 |
| DELETE | `/account`               | Purge all user data.                           |
| WS     | `/live?token=<uid>`      | Talk-to-AI channel (Gemini Live proxy).        |
| POST   | `/dev/seed-transcript`   | Mock-only: attach a transcript to an audio obj.|

## Auth

Every request carries a Firebase ID token (`Authorization: Bearer <token>`). In mock mode the token
is treated as the `uid` (or pass `X-Debug-Uid`) so the API is trivially exercisable.
