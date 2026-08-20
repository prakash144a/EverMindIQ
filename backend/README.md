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
uvicorn app.main:app --reload        # http://localhost:8000/docs
```

No copying step: `config/local.env` is committed and is the default profile, so a
fresh clone runs offline in mock mode with no credentials.

## Configuration

Two profiles in `config/`, selected by `VOICEIQ_ENV` (unset means `local`):

| File | Committed? | Used for |
|---|---|---|
| `config/local.env` | yes | local dev, the Android emulator, the test suite. No secrets. |
| `config/production.env` | **no** — gitignored | real GCP, real Gemini, the Azure credential |
| `config/production.env.example` | yes | template for the above; recreate it in a fresh clone |

`local.env` always loads first and the profile layers on top, so `production.env`
only states what differs. Run against real cloud with:

```bash
VOICEIQ_ENV=production uvicorn app.main:app --reload
```

Neither file reaches Cloud Run — the Dockerfile copies only `pyproject.toml` and
`app/`. Production is configured by the env vars Terraform sets on the service,
and Terraform reads the `VOICEIQ_MODEL_*` lines out of `config/production.env`,
so the model written there is the model production runs after `terraform apply`.
Never use a `-latest` model alias: Vertex publishes none, and the call fails
outright. `tests/test_model_config_consistency.py` enforces all of this.

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
| GET    | `/health`                | Liveness + mode.                               |
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
