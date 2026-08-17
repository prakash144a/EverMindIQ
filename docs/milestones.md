# MemoriesIQ / VoiceIQ — Milestones & Progress

A living tracker for every phase and major work item. Update the status boxes as work lands.
Aligns with the phased delivery in [architecture.md §8](./architecture.md).

**Last updated:** 2026-08-17 (admin console live at `memoriesiq-admin.web.app`; backend deployed;
Firestore indexes deployable for the first time; CI lint gate fixed)

## Status legend

- `[x]` ✅ Done — implemented and working
- `[~]` 🟡 Partial — works in **mock mode**, but the real/cloud path is stubbed (`# pragma: no cover`) and unexercised, or only part of the scope is done
- `[ ]` ⬜ Not started

> **Big-picture state:** the core loop is **real**. As of 2026-08-16 a recording goes from a signed
> upload into the CMEK bucket, through Pub/Sub to real Gemini transcription and enrichment, into
> Vertex embeddings and Firestore, and comes back out of a RAG query with a citation — against live
> GCP, in under 10 seconds. Mock mode remains the offline/test path. What's left is not "make the
> cloud path work" any more; it's release readiness (Android signing, CI deploy automation), the
> Phase 2 features that were only ever mocked, and the deferred cost work in Phase 4.

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
- [x] Firebase setup — project added to Firebase, Android app `com.example.voiceiq` registered,
  `google-services.json` + `firebase_options.dart` generated, **Anonymous provider enabled**, backend
  SA granted `firebaseauth.viewer`. App Check: later.

## Phase 1 — MVP

- [x] Record a moment, with back-dating (`occurred_at`)
- [x] Calendar view of moments
- [x] Talk-to-AI **text** chat (over the `/live` WebSocket)
- [x] In-app **audio playback** of recordings (`GET /recordings/{id}/audio`)
- [x] Record / Recall action menu (the `+` FAB)
- [x] Encrypted upload to GCS + CMEK — **verified in real mode** (2026-08-16): `POST /uploads` signs a
  V4 URL via IAM `signBlob` from Cloud Run's keyless credentials, and a direct client `PUT` to the
  CMEK bucket returns 200
- [x] Ingestion pipeline (transcribe → summarize → chunk → embed → index) — **verified in real mode**
  (2026-08-16): Pub/Sub → `/internal/ingest` → real Gemini transcription (accurate, correct language
  detection) → enrichment (title, summary, tags, people, places, mood) → Vertex multilingual
  embeddings → Firestore chunks. End to end in **under 10 seconds**; RAG recall returned a grounded
  answer with a citation at cosine 0.599. Cross-lingual recall is **still unverified** — no non-English
  audio was available to test with (see Phase 2)
- [x] Auth via Firebase ID token — app signs in with **Firebase Anonymous auth** and sends a live ID
  token; backend verifies it (REST + `/live` WS). **Verified end-to-end**: a real anonymous token →
  `GET /recordings` → 200. App Check: later.
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

## Phase 3.5 — Operations & launch surface

- [x] **Renamed the product to MemoriesIQ** — launcher label, in-app title, onboarding copy, web
  title/manifest, pubspec description, and the `MemoriesIQApp` widget. `AppConfig.appName` is now the
  single source. VoiceIQ deliberately stays as the internal name for the backend, the `VOICEIQ_` env
  prefix, the Dart package, and every GCP resource
- [x] **Android application id** → `com.memoriesiq.app` (was `com.example.voiceiq`, which the Play
  Store rejects outright). **Blocked on a manual step**: the new package must be registered in the
  Firebase console and `google-services.json` regenerated, or the Android build fails
- [x] **Admin console** (`admin/`) — React + Vite SPA: overview with charts, paginated/searchable
  people list, per-account detail, device view, cross-user feedback inbox with triage, pipeline
  health, and an admin audit log
- [x] **Admin API** (`/admin/*`) — allowlist authorization (`require_admin`), fail-closed on an empty
  allowlist, and a hard rule that **no endpoint returns any user's content**, enforced structurally by
  the response models and by `test_admin_privacy.py`
- [x] **Per-user stats** — denormalized counters in a top-level `userStats` collection so the console
  never walks every user's recordings. Kept out of `users/{uid}` because that document is
  client-writable, so a `tier` there could be self-granted
- [x] **Device ↔ account tracking** — install UUID (not a hardware id) sent as a request header and
  throttled to ~one write per user per day. Survives sign-out, so the console can show several
  accounts on one phone once account switching ships
- [x] **Premium/free tier** — admin-set flag with an audit trail. A label, not an entitlement:
  nothing in the app enforces a limit yet
- [x] **Marketing site** (`site/`) — static HTML for ad traffic, plus the privacy policy the Play
  listing requires. **Placeholders still to fill**: legal entity, address, contact, jurisdiction
- [x] **Firebase Hosting** — two targets (`site`, `admin`) in `firebase.json` + `.firebaserc`;
  `firebasehosting.googleapis.com` enabled in Terraform
- [x] **Firebase web app registered + Google sign-in enabled**; admin console deployed to
  `https://memoriesiq-admin.web.app` with the allowlist set on Cloud Run
- [x] ~~Run the stats backfill~~ — **not required.** The script
  (`backend/scripts/backfill_user_stats.py`) is kept for the case where pre-`userStats` accounts ever
  need reconstructing, but the existing accounts are throwaway test identities not worth importing
- [ ] **Publish the marketing site** — legal pages are filled in
  (NATIVE MINDS AI LABS); the governing jurisdiction and the US$100 liability cap were inferred from
  the registered address and want a lawyer's confirmation before the site takes ad traffic
- [ ] **Decide what premium actually unlocks** — deferred; the toggle exists, is audited, and
  currently changes nothing for the user

---

## Phase 4 — Cost optimization (post-launch)

> **Deliberately deferred.** None of this changes what the product does; it changes what it costs to
> run. Doing it before launch would trade shipping speed for savings on traffic that doesn't exist
> yet. Revisit once there are real users and the billing dashboard shows where the money actually
> goes — the ranking below is by expected impact, not by effort. Baseline guardrail today: the
> **$50/mo budget** with alerts (Phase 0) and Cloud Run `min_instance_count = 0`.

- [ ] **Kill the O(N) scan on every recall query** — `FirestoreRepository.vector_search`
  (`backend/app/services/firestore.py`) loads *every* recording doc + *every* chunks doc for the user
  and computes cosine in Python, so one question costs ~2N document reads and drags full transcripts
  over the wire. Move to Firestore native `find_nearest` KNN (one chunk per doc + a vector index) so
  reads drop to `top_k`. Note this **inverts** the one-doc-per-recording packing in `chunks_to_doc`,
  which exists only as a defense against the brute-force scan. Overlaps with the Phase 3 "Migrate
  retrieval to Vertex AI Vector Search" item — decide between Firestore KNN and Vertex there.
- [ ] **Fix the polling read amplification** — `RecordingsNotifier` (`app/lib/src/data/providers.dart`)
  polls `listRecordings()` every 5s up to 24 times while a transcript is in flight, and each call
  streams the **entire** recordings collection with full transcripts. One new recording currently
  costs up to 24 × N document reads. Poll the single pending recording by id instead: 24 reads, flat.
- [ ] **Stop translating + double-embedding non-English memories** — the enrich prompt always asks for
  `transcript_en` and `pipeline/ingest.py` then embeds those chunks too. (Verified 2026-08-16: it comes
  back empty for English input, so this costs nothing there — but it doubles output tokens, embeddings,
  storage and scan cost for **every** non-English memory, i.e. the target users.) The embedder is
  already **multilingual** precisely so an
  English query matches a Tamil memory, so the second copy is largely redundant. Translate only when
  the user wants a readable English version, and don't embed both.
- [ ] **Merge transcribe + enrich into one Gemini call** — today it's two round trips and the
  transcript is paid for twice (once as audio-in, once as text-in). One call — audio in, JSON out with
  transcript + title + summary + tags — roughly halves per-recording LLM cost.
- [ ] **Add a lifecycle policy to the audio bucket** — `google_storage_bucket.audio` (`infra/main.tf`)
  has none. Audio is written once and rarely replayed: Nearline at 30 days, Coldline at 365. 50–75%
  off storage with no UX change, since the searchable artifact (the transcript) lives in Firestore.
- [ ] **Decide raw-audio retention** — the largest byte volume by far, and retrieval never touches it
  once the transcript exists. Dropping or cold-archiving audio past a window is the biggest long-term
  lever. Product call (users may expect to replay their own voice), not a purely technical one.
- [ ] **Cheaper model slot for enrichment** — `model_reasoning` (`gemini-flash-latest`) handles both
  transcription and enrichment; enrichment is a structured-extraction task that a flash-lite tier may
  serve at lower cost. Measure output quality before switching.

---

## Cross-cutting / near-term cleanups

- [ ] Android **release** readiness: HTTPS backend, app signing, real app id + icon (currently `com.example.voiceiq`; cleartext is debug-only)
- [ ] Revisit the `record` dependency: the `record_linux: 1.3.1` override unblocks the build — consider bumping `record` to its aligned 6.x line instead
- [x] **Real-mode end-to-end verification pass** (2026-08-16) — record → GCS/CMEK → Pub/Sub → Gemini →
  embeddings → Firestore → RAG recall, all exercised against live GCP with a real Firebase anonymous
  token. Per-user isolation confirmed (a second anonymous user sees an empty list). Three defects were
  found and fixed; two remain open below.
- [x] Audio container handling — uploads were stored as `.m4a` regardless of the declared
  `content_type`, and served back as `audio/mp4`, so web (`audio/webm`) playback was broken and Gemini
  received a hardcoded, non-IANA `audio/m4a`. Now derived from one table (`app/core/media.py`)
- [x] Audio blobs are deleted with their recording — `DELETE /recordings/{id}` left the GCS object
  behind forever (confirmed against the live bucket): a storage cost, and audio the user believes is
  gone. Account purge now also sweeps the whole `users/{uid}/audio/` prefix, which `account.py` had
  documented but never implemented
- [x] **CI lint gate fixed** — was red on *every* run since the initial commit, because `ruff>=0.5`
  resolved to 0.16.x and flagged widespread pre-existing code (86 findings: `B008` on every FastAPI
  `Depends`, `UP017`, `DTZ011`, …). Ruff is now pinned to `>=0.16,<0.17` and `[tool.ruff.lint] select`
  is explicit (`E`, `W`, `F`, `I`), with `B008`/`UP017` excluded and the reason recorded in
  `pyproject.toml`. The remaining 9 real findings were fixed; `ruff check app tests` passes clean
- [x] **Firestore indexes were never deployable** — `firestore.indexes.json` declared the
  `chunks.embedding` vector index in a shape the CLI rejects, so `firebase deploy --only
  firestore:indexes` failed every time it ran, including inside the gated CI deploy job. The
  declaration was also meaningless: `chunks_to_doc` packs all chunks into one document, so no
  root-level `embedding` field exists to index. Removed; it belongs with the Phase 4 `find_nearest`
  migration that changes that layout. Two further fixes: single-field **collection-group** queries
  (`feedback.created_at`, `recordings.status`) need field overrides, not composite indexes —
  Firestore rejects the latter with "this index is not necessary" or fails the query at runtime
- [x] **A 500 used to reach the browser as "Failed to fetch"** — Starlette's error middleware sits
  *outside* `CORSMiddleware`, so an unhandled exception returned a bare 500 with no
  `Access-Control-Allow-Origin`, which a browser cannot read. The admin console showed a network
  error while the real cause (a missing index) sat in the logs. Errors are now converted to JSON
  inside the CORS layer (`app/main.py`), covered by `tests/test_error_responses.py`
- [ ] Cross-lingual recall unverified — the multilingual embedder is the load-bearing choice for the
  target users (Tamil/Hindi memories, English questions) and has never been tested with non-English
  audio. Needs a real non-English recording through the live pipeline

---

## Progress snapshot

| Phase | Done | Partial (mock) | Not started |
|-------|:----:|:--------------:|:-----------:|
| 0 — Foundations | 7 | 0 | 1 |
| 1 — MVP | 8 | 0 | 1 |
| 2 — Enrichment | 0 | 2 | 2 |
| 3 — Scale & polish | 0 | 1 | 5 |
| 3.5 — Operations & launch | 11 | 0 | 2 |
| 4 — Cost optimization | 0 | 0 | 7 |
| Cross-cutting | 6 | 0 | 3 |

## Maintaining this doc

- Flip a box (`[ ]` → `[~]` → `[x]`) as work lands, and refresh **Last updated** + the snapshot table.
- Promote a `[~]` to `[x]` only once the **real (non-mock) path** is exercised, not just the mock.
- Add new major work as a checklist item under the phase it belongs to; keep one line per item.
