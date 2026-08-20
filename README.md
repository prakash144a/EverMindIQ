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

## Status

MVP-first build. See [`docs/architecture.md`](docs/architecture.md) §8 for phased delivery.
