# MemoriesIQ (VoiceIQ / EverMindIQ)

AI-native voice app for capturing important life moments by voice — and later *talking to an AI*
that can recall and reason across a lifetime of those memories.

> **On the names.** **MemoriesIQ** is the product: it is what the app is called, what the launcher
> shows, and what the marketing site sells. **VoiceIQ** is the internal name and stays that way —
> the backend service, the `VOICEIQ_` env prefix, the GCP project, and every Terraform resource. The
> split is intentional; renaming live cloud resources buys nothing a user would ever notice.

- **Record** a moment by voice (defaults to now, can back-date to any day).
- **Talk to AI** in real time to ask anything about your past memories (Gemini Live).
- **Home** resurfaces meaningful moments ("On This Day" — 1 / 5 / N years ago).
- **Calendar** browses recordings by day.
- **Insights** summarize themes over day / week / month / year / 5y / lifetime / custom ranges.

Record in any language (Tamil, Hindi, French, …) and ask in any language — cross-lingual recall
is built in via multilingual embeddings.

## Monorepo layout

```
EverMindIQ/
├── app/        # Flutter client (iOS + Android)
├── backend/    # FastAPI service on Cloud Run (API, ingestion, RAG, Live proxy)
├── admin/      # Operator console (React + Vite), talks to the backend's /admin API
├── site/       # Public marketing site — static HTML, no build step
├── infra/      # Terraform (GCS+CMEK, Firestore, Pub/Sub, Cloud Run, Secret Manager)
├── tools/      # One-off generators (branding/ regenerates every app icon)
├── docs/       # Architecture & design docs
└── README.md
```

`admin/` and `site/` both deploy to Firebase Hosting as separate targets (`firebase.json`).

## Tech stack

| Layer            | Choice                                                        |
|------------------|---------------------------------------------------------------|
| Mobile           | Flutter (Dart 3), Material 3, Riverpod, go_router             |
| Backend          | Python FastAPI on Cloud Run                                    |
| Auth             | Firebase Auth (Google / Apple / email) + App Check            |
| Metadata DB      | Firestore                                                     |
| Object store     | Cloud Storage (GCS) + CMEK (Cloud KMS)                         |
| Vectors          | Firestore Vector Search (MVP) → Vertex AI Vector Search (scale)|
| Async pipeline   | Pub/Sub + Cloud Run worker                                    |
| AI               | Latest GA Gemini (RAG), Gemini Live (voice), multilingual embeddings |

See [`docs/architecture.md`](docs/architecture.md) for the full design.

## Quick start

### Backend
```bash
cd backend
python -m venv .venv && source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -e ".[dev]"
cp .env.example .env            # fill in GCP project etc. (mock mode works with defaults)
uvicorn app.main:app --reload   # http://localhost:8000/docs
pytest                          # runs green with external services mocked
```

### App
```bash
cd app
flutter pub get
flutter run                     # point API_BASE_URL at your backend
```

Against the **mock backend** add `--dart-define=MOCK_AUTH=true`. Mock mode has no Firebase — the
"custom token" it returns is the uid — so without this the app hands that string to
`signInWithCustomToken` and never gets past the login screen.

### The web app
```bash
cd app
flutter run -d chrome --web-port=8080   --dart-define=MOCK_AUTH=true --dart-define=API_BASE_URL=http://localhost:8000
```

Port 8080 because that is the origin the deployed backend's CORS allowlist names
(`infra/terraform.tfvars`); against a local backend any port works. `localhost` is a secure context,
so the microphone is available without TLS.

### Signing in locally

Mock mode sends no email. The code is pinned to **`123456`** (`VOICEIQ_MOCK_OTP_CODE` in
`config/local.env`) and logged on every request, so local sign-in needs no inbox. Blank that setting
for random codes, which is what the test suite runs with. It is honoured only when `effective_mock`
is true, so a deployment with a GCP project configured cannot issue a code anyone can guess.

## Status

MVP-first build. See [`docs/architecture.md`](docs/architecture.md) §8 for phased delivery.
