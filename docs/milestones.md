# VoiceIQ / EverMindIQ — Milestones & Progress

A living tracker for every phase and major work item. Update the status boxes as work lands.
Aligns with the phased delivery in [architecture.md §7](./architecture.md).

**Last updated:** 2026-08-12 (Firebase Anonymous auth wired into the app)

## Status legend

- `[x]` ✅ Done — implemented and working
- `[~]` 🟡 Partial — works in **mock mode**, but the real/cloud path is stubbed (`# pragma: no cover`) and unexercised, or only part of the scope is done
- `[ ]` ⬜ Not started

> **Big-picture state:** the whole app + backend run **end-to-end in mock mode, fully offline**.
> Every cloud integration (Firebase auth, GCS/CMEK, Gemini, Firestore, Vertex) has a mock
> implementation; the real branches exist but have **never run against live GCP**. The central
> theme of the remaining work is turning the mock prototype into a real, deployed product.

---

## Phase 0 — Foundations

- [x] Flutter app shell + bottom navigation (Home / Calendar / Talk / Insights)
- [x] CI pipeline — lint + test for backend and app (`.github/workflows/ci.yml`)
- [x] Android build wired up + runs on emulator against the mock backend (`10.0.2.2:8000`)
- [x] **Deployment pipeline authored** — Terraform is now apply-ready (enabled APIs, CMEK audio
  bucket, Firestore, Pub/Sub topic+sub, backend SA + least-privilege IAM, Secret Manager,
  **Artifact Registry**, Cloud Run + **public invoker**), plus a gated CI `deploy` job
  (build image → Cloud Run → Firestore rules/indexes) behind `DEPLOY_ENABLED`
- [x] **Provision GCP infrastructure** — `terraform apply` against project **`voiceiq-505205`**
  (2026-08-10); resources live. State is local in `infra/` (gitignored). A **$50/mo billing budget**
  with $5/$20/$40/$50 alerts is also applied.
- [x] **First real backend deploy** — image `…/voiceiq/api:v1` built via Cloud Build and deployed to
  Cloud Run (drift-free via `container_image` in tfvars). Live at
  `https://voiceiq-api-fv2se2zeza-uc.a.run.app` in real mode; `/docs` + auth verified.
- [ ] Automate deploy in CI — Workload Identity Federation + repo vars/secrets (`DEPLOY_ENABLED`, etc.)
  so pushes to `main` redeploy (today's deploy was manual)
- [~] Firebase setup — project added to Firebase, Android app `com.example.voiceiq` registered,
  `google-services.json` + `firebase_options.dart` generated. **Remaining:** enable the Anonymous
  sign-in provider (console) + `terraform apply` the `VOICEIQ_FIREBASE_PROJECT` env. App Check: later.

## Phase 1 — MVP

- [x] Record a moment, with back-dating (`occurred_at`)
- [x] Calendar view of moments
- [x] Talk-to-AI **text** chat (over the `/live` WebSocket)
- [x] In-app **audio playback** of recordings (`GET /recordings/{id}/audio`)
- [x] Record / Recall action menu (the `+` FAB)
- [~] Encrypted upload to GCS + CMEK — mock storage works; real GCS/CMEK path stubbed
- [~] Ingestion pipeline (transcribe → summarize → chunk → embed → index) — mock works; real Gemini + embeddings stubbed
- [~] Auth via Firebase ID token — backend verifies real tokens (REST + `/live` WS); app now signs in
  with **Firebase Anonymous auth** and sends a live ID token (committed). Pending: enable the Anonymous
  provider + deploy the backend env, then verify end-to-end. App Check: later.
- [ ] Talk-to-AI **voice** (Gemini Live, client mic streaming over WSS) — **not built** (text only)

## Phase 2 — Enrichment

- [~] "On This Day" resurfacing — mock implemented + Home wired; real **nightly precompute + Cloud Scheduler** pending
- [~] Insights summaries — mock implemented; real map-reduce over Gemini pending
- [ ] Entity extraction + search — not built
- [ ] Push notifications (FCM) — not built

## Phase 3 — Scale & polish

- [~] Milestones — detection + ⭐ display present (`pipeline`, Home, Calendar); dedicated milestones view/management pending
- [ ] Migrate retrieval to **Vertex AI Vector Search** (currently mock / Firestore-style)
- [ ] Data export
- [ ] Account-deletion purge across GCS + Firestore + vectors (`account` router exists; real purge stubbed)
- [ ] Retrieval / prompt tuning
- [ ] Optional end-to-end encryption tier

---

## Cross-cutting / near-term cleanups

- [ ] Android **release** readiness: HTTPS backend, app signing, real app id + icon (currently `com.example.voiceiq`; cleartext is debug-only)
- [ ] Revisit the `record` dependency: the `record_linux: 1.3.1` override unblocks the build — consider bumping `record` to its aligned 6.x line instead
- [ ] Real-mode end-to-end verification pass: exercise the cloud branches currently behind `# pragma: no cover`

---

## Progress snapshot

| Phase | Done | Partial (mock) | Not started |
|-------|:----:|:--------------:|:-----------:|
| 0 — Foundations | 6 | 0 | 2 |
| 1 — MVP | 5 | 3 | 1 |
| 2 — Enrichment | 0 | 2 | 2 |
| 3 — Scale & polish | 0 | 1 | 5 |
| Cross-cutting | 0 | 0 | 3 |

## Maintaining this doc

- Flip a box (`[ ]` → `[~]` → `[x]`) as work lands, and refresh **Last updated** + the snapshot table.
- Promote a `[~]` to `[x]` only once the **real (non-mock) path** is exercised, not just the mock.
- Add new major work as a checklist item under the phase it belongs to; keep one line per item.
