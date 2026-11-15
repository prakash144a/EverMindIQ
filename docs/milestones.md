# MemoriesIQ / VoiceIQ — Milestones & Progress

A living tracker for every phase and major work item. Update the status boxes as work lands.
Aligns with the phased delivery in [architecture.md §8](./architecture.md).

**Last updated:** 2026-10-04 (**a memory can now be renamed, retitled by the AI and reworded** for
seven days after it is saved, and its title and summary have a language setting of their own — live
on backend `api:v16` and in the web build; the app running in a browser, with one account open on a
phone and a browser at once, came just before it. All of it sits on the `tier-limits-and-deletion`
branch, **21 commits ahead of `main` and not merged**. One commit is **not yet deployed**: the
sign-in email saying MemoriesIQ rather than VoiceIQ)

## Status legend

- `[x]` ✅ Done — implemented and working
- `[~]` 🟡 Partial — works in **mock mode**, but the real/cloud path is stubbed (`# pragma: no cover`) and unexercised, or only part of the scope is done
- `[ ]` ⬜ Not started

> **Big-picture state:** the core loop is **real** and there is now an **operator plane** over it. A
> recording goes from a signed upload into the CMEK bucket, through Pub/Sub to real Gemini
> transcription and enrichment, into Vertex embeddings and Firestore, and back out of a RAG query
> with a citation — against live GCP, in under 10 seconds. A **typed** memory takes the same route
> from enrichment onward. An admin console reports who is using it, and the same account opens in a
> browser as well as on a phone.
> Mock mode remains the offline/test path. What's left is release readiness (app signing, the Play
> listing, getting the work onto `main` with CI green and deploys automated), the two things never
> exercised against the live model (a real voice conversation, cross-lingual recall), the Phase 2
> features that were only ever mocked, and the deferred cost work in Phase 4.

## What is live right now

| | |
|---|---|
| API | `https://voiceiq-api-fv2se2zeza-uc.a.run.app` — image `api:v16`, real mode, revision `voiceiq-api-00019-gts` (2026-10-04; read back with `gcloud run services describe` after the apply). Adds memory editing: the `summary_language` setting, `title` and `transcript` on `PATCH /recordings/{id}`, `POST /recordings/{id}/title`, and the seven-day edit window. Still carries two-surface sessions, the name-after-code sign-in, and the ingestion delete-race fix, which has been in every image since `v13`. **Does not carry** the sign-in email rename (`2dcd715`), so that email still says VoiceIQ until the next image. |
| Web app | `https://app.memoriesiq.nativemindsai.com` — the Flutter web build on an Azure Static Web App, deployed by hand with the SWA CLI (see [`app/README.md`](../app/README.md)). Rebuilt and redeployed 2026-10-04 with the memory-editing controls, after `api:v16` was live |
| Marketing site | `https://memoriesiq.nativemindsai.com` — Azure Static Web App, also deployed by hand (see [`site/README.md`](../site/README.md)). The privacy policy is at `/privacy.html` |
| Admin console | `https://memoriesiq-admin.web.app` — allowlisted Google sign-in, Firebase Hosting |
| GCP / Firebase | project `voiceiq-505205`, region `us-central1` |
| Android package | `com.memoriesiq.app` (registered in Firebase; the old `com.example.voiceiq` app still exists and can be deleted once a build is confirmed) |
| Branch | `tier-limits-and-deletion` — 21 commits ahead of `main`, no pull request open. `main` is still at `f107e5a` (2026-08-18), so everything from the tier limits onward is deployed but unmerged |
| CI | **red on `main`** — the last run was `f107e5a` (2026-08-18) and its backend job failed. CI triggers on pushes to `main` and on pull requests only, so it has **never run** on the 21 commits since. `deploy` is still gated on `DEPLOY_ENABLED` and has never run |
| Tests | Run locally 2026-10-04: 417 backend, 174 app, `flutter analyze` clean, `tsc --noEmit` clean. `ruff check app tests` reports **2 findings**, both in `tests/test_otp_mock_code.py` (`I001` import order, `E501` line length) — enough to fail the CI lint gate |

> **Before running Terraform in a fresh clone:** `infra/secrets.auto.tfvars` is **gitignored** and
> must be recreated — it holds `billing_account` and `admin_emails`. Without it `apply` prompts for
> the billing account and the admin allowlist is empty, which locks everyone out of `/admin` by
> design. See [`infra/README.md`](../infra/README.md).

> **Backend configuration is two profiles**, in `backend/config/`, selected by `VOICEIQ_ENV`
> (unset = `local`). `local.env` is committed, secret-free, and covers local dev, the emulator and
> the test suite; `production.env` is **gitignored** — it holds the ACS connection string and the
> repo is public — with `production.env.example` committed in its place. `local.env` always loads
> first and the profile layers on top, so `production.env` states only what differs.
>
> **Which model production runs:** `backend/config/production.env`. Terraform parses
> `VOICEIQ_MODEL_*` out of it and sets those as Cloud Run env vars, so the file a developer edits is
> the file production deploys — change a model there and `terraform apply` carries it (verified by
> plan, 2026-08-18). A fresh clone or CI falls back to `production.env.example`, and
> `backend/tests/test_model_config_consistency.py` (16 tests) keeps every copy — code defaults,
> both profiles, `variables.tf`, and the `env` blocks in `main.tf` — from drifting, and asserts the
> secret file stays out of git and out of the Cloud Build context. **The CI `deploy` job does not
> carry model changes** — it runs `gcloud run deploy --image` with no `--set-env-vars`, which
> preserves the service's existing environment; a model change needs `terraform apply`. Never use a
> `-latest` alias: none is published on Vertex.
>
> **Email is wired to production** (2026-08-18). Terraform reads the ACS connection string from
> `production.env`, stores it as a `voiceiq-acs-connection` Secret Manager version, and Cloud Run
> mounts it into `VOICEIQ_ACS_CONNECTION_STRING` via `secret_key_ref` — so the credential is never a
> readable value in the console, in `gcloud run describe`, or in a deploy log. The sender address is
> a plain env var, being on every email anyway. A `precondition` fails the apply with a clear message
> if the credential is empty, which is what a fresh clone would otherwise publish, silently breaking
> sign-in email. **Applied** — the `voiceiq-acs-connection` secret is in Terraform state (checked
2026-10-04). The unused
> `google_secret_manager_secret.app` is deliberately kept: it holds a hand-added version from the
> verification pass, and dropping it from the config would delete it.

## Next session — start here

Ordered by what unblocks the most. (1) gates (6); the rest are independent.

1. **Get the branch onto `main` with CI green** — Cross-cutting. Production runs code that `main`
   does not have: 21 commits on `tier-limits-and-deletion`, no pull request, and CI has not run on
   any of them. Fix the two ruff findings in `tests/test_otp_mock_code.py`, open the PR (which is
   what triggers CI), and merge.
2. **Play Store readiness** — Cross-cutting. Release builds still sign with the debug keystore. The
   privacy-policy URL the listing needs now exists, so nothing upstream blocks this any more. It is
   the real blocker to shipping the Android app at all.
3. **Lawyer's sign-off on the terms** — Phase 3.5. The site is public, so this is no longer a gate
   on publishing; it is a gate on sending paid traffic to it. Still unconfirmed: the governing
   jurisdiction, the US$100 liability cap, and now the three clauses added on 2026-10-03.
4. **Hold a real voice conversation** — Phase 1. The endpoint has been in production since `api:v12`
   and the conversation has still never happened. Everything past `client.aio.live.connect` is
   `# pragma: no cover` and the SDK's message shapes are the part most likely to have moved. Do this
   in **Tamil or Hindi** and it also closes (5). It can now be tried from a browser as well.
5. **Verify cross-lingual recall** — Cross-cutting. The load-bearing unverified assumption for the
   target users; needs one real non-English recording through the live pipeline.
6. **Automate deploys in CI** — Phase 0. Every deploy so far has been manual, and there are now
   three surfaces deployed by hand: Cloud Run and the two Azure Static Web Apps. The written job
   covers only the first, plus Firestore rules and the admin console.
7. **A way to buy premium** — Phase 3.5, product decision. Five limits are enforced and the admin
   console has an explicit "Upgrade to Pro", but premium is still granted by hand. What remains is
   whether the five are *enough* to charge for, and then a purchase flow.

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
- [ ] Automate deploy in CI — Workload Identity Federation + repo vars/secrets (`DEPLOY_ENABLED`,
  `GCP_PROJECT_ID`, `GCP_REGION`, `GCP_WIF_PROVIDER`, `GCP_DEPLOY_SA`, plus the `FIREBASE_WEB_*` vars
  the admin build needs) so pushes to `main` redeploy. Every deploy to date has been manual. The job
  itself is written and has never run — worth a dry run on a throwaway branch before trusting it.
  It covers Cloud Run, Firestore rules/indexes and the admin console; the two Azure Static Web Apps
  (marketing site, web app) are deployed by hand with the SWA CLI and would need steps of their own
- [x] Firebase setup — project added to Firebase; Android app **`com.memoriesiq.app`** and a **web**
  app registered; `google-services.json` + `firebase_options.dart` generated; **Anonymous and Google
  providers enabled**; backend SA granted `firebaseauth.viewer`. App Check: later.

## Phase 1 — MVP

- [x] Record a moment, with back-dating (`occurred_at`)
- [x] **Type a memory instead of speaking it** — the capture screen now has a **Speak / Write**
  toggle. A typed memory has no audio and no transcription: the text *is* the transcript, so
  ingestion joins at enrichment (`pipeline/ingest.py` branches on `Recording.source`) and the memory
  is enriched, embedded, indexed and recallable exactly like a spoken one. Enrichment now also
  reports the detected language, because nothing upstream determined it — which matters most for the
  users likeliest to type in Tamil or Hindi. New `POST /recordings/text`; the four places that
  assumed audio (Home, Milestones, Calendar, Recall citations) check `hasAudio` first
- [x] **A typed memory is kept as a draft until it is saved** (2026-10-03) — every change is written
  to a draft the screen restores on opening, so closing the screen, refreshing the tab or the app
  being put away no longer loses it. Cleared on a successful save and on sign-out, so a shared device
  does not hand the next person an unfinished sentence
- [x] Calendar view of moments
- [x] Talk-to-AI **text** chat — a typed question is an ordinary request to `/chat` (2026-10-03). It
  used to ride the `/live` WebSocket, which had quietly stopped working: the socket was opened without
  the session id every other call carries, the handshake was refused, and a question sat at
  "Recalling…" forever. A failure is now said in the conversation
- [x] In-app **audio playback** of recordings (`GET /recordings/{id}/audio`)
- [x] **Memory detail view** — every list row now opens the memory in full: the transcript (labelled
  as AI-produced, since it is a best guess), the summary, people/places/tags/mood, the star, and
  playback when there is audio. Reads from `recordingsProvider` by id rather than taking a snapshot,
  so a transcript that lands while the screen is open appears. Before this the app had **no detail
  screen at all** — a recording could be played but never read, and a typed memory could not be
  revisited in any form. Tappable from Home recents, the milestone rail, Milestones, Calendar, and
  Recall citations
- [x] **Editing a memory, for seven days** (2026-10-04) — the title can be renamed (no AI call) or
  handed back to the AI for a different one (`POST /recordings/{id}/title`); the words can be
  rewritten, typed or transcribed, which re-runs enrichment and indexing so the summary, entities
  and vectors follow them while the title is kept. The summary has no edit of its own. All three
  close seven days after capture (`memory_edit_window_days`, published on `GET /profile`), with the
  controls left on the page disabled and a line saying why; starring, filing and deleting stay open.
  Title and summary are written in a new `summary_language` setting — "Match the memory" or a named
  language — because the old prompt passed the answer-language default, the bare word "auto", and
  the model guessed. Deployed in `api:v16` and the web build. **Tested in mock mode only**: the
  rewritten enrichment prompt and the new title prompt have not been run against the live model.
  Neither edits nor new titles are metered, so each one inside the window is a model call
- [x] **Journals** — named containers, one per memory, filed by hand at capture and reassignable from
  the memory detail view. `users/{uid}/journals/{id}`; `journal_id` on the recording; full CRUD at
  `/journals`; deleting one unfiles its memories rather than deleting them. **Recall can be scoped to
  one journal** — by the picker, or by naming it in the question
  (`pipeline/journal_scope`, a word match, not a second model call) — and the answer says which
  journal it used so a narrowing is always one tap from being undone
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
- [~] **Talk-to-AI voice** (Gemini Live, client mic streaming over WSS) — **built, unverified against
  the live model.** The app streams 16 kHz PCM16 from the mic over the existing `/live` socket and
  plays Gemini's 24 kHz voice back; binary frames are audio, JSON frames are control. The on-device
  `speech_to_text` and `flutter_tts` are **gone** — they were the reason every answer was read back
  in an `en-US` voice to users whose memories are in Tamil or Hindi, and the whole point of moving to
  native audio is that one model now hears and speaks those directly. Memories reach the model as a
  `recall_memories` **tool** rather than as context injected per turn, because a spoken conversation
  has no single question to retrieve for; the tool runs the same `pipeline.rag.retrieve` as the text
  path and its hits are sent on as citations. Barge-in works by keeping the speaker's buffer shallow
  (`flutter_pcm_sound` cannot flush what it has accepted) and dropping the rest on `interrupted`.
  The model slot is pinned in `infra/main.tf` to **`gemini-live-2.5-flash-native-audio`** — the only
  Live-API model published in `us-central1` for this project, and a native-audio one, so the voice
  has real prosody instead of a synthesizer reading text. The code default `gemini-live-latest` would
  have 404'd on connect: **no `-latest` alias is published on Vertex here at all** (confirmed against
  the live publisher list, 2026-08-18), which is the same trap already noted for the reasoning and
  embedding slots.
  Note `flutter_pcm_sound` pins `compileSdkVersion 33` while its own androidx dependencies demand
  34+, which fails the AAR metadata check for the whole build; `android/build.gradle.kts` now raises
  any lagging plugin to the app's 36 rather than pinning the app back.
  The browser build plays the same stream through Web Audio (`PcmPlayer`, 2026-10-03), because
  `flutter_pcm_sound` is Android, iOS and macOS only.
  Promote to `[x]` once a real conversation has run against the deployed backend

## Phase 2 — Enrichment

- [~] "On This Day" resurfacing — mock implemented + Home wired; real **nightly precompute + Cloud Scheduler** pending
- [~] Insights summaries — mock implemented; real map-reduce over Gemini pending
- [ ] Entity extraction + search — not built
- [ ] Push notifications (FCM) — not built
- [ ] **Photos, videos and files on a memory** — not built. The capture screen carries a placeholder
  (`AttachPlaceholderButton`) whose every entry is disabled and which opens no picker; it settles
  where the control goes and nothing more

## Phase 3 — Scale & polish

- [~] Milestones — detection + ⭐ display present (`pipeline`, Home, Calendar); dedicated milestones view/management pending
- [ ] Migrate retrieval to **Vertex AI Vector Search** (currently mock / Firestore-style)
- [ ] Data export
- [x] **Deleting a memory, and deleting an account** — both reachable from the app, and both total.
  A memory takes its metadata, its chunks (the search index), its audio object **and the derived
  caches** with it; the last one is the leak worth naming, because an On This Day feed item copies a
  title and summary out of the recording and is served from storage, so without the purge a deleted
  memory kept reading back to the person who deleted it (`_purge_derived_quietly`, pinned by
  `tests/test_deletion.py`). Account deletion additionally sweeps journals, insights, feedback,
  settings, stats, the device links and the email index, plus every object under the user's storage
  prefix — by prefix, so it also collects blobs whose recording was never registered. The app asks
  before either: a spelled-out dialog for one memory, and a screen that counts what is at stake and
  requires typing DELETE for the account. Neither offers an undo, because there is not one
- [x] **The delete-vs-ingestion race** (2026-08-19) — found by verifying the `api:v12` deploy against
  production, *not* by the suite: deleting a memory within ~6s of creating it was silently undone,
  because ingestion is a read-modify-write with a Pub/Sub hop and several seconds of Gemini in the
  middle and its final write **upserted**. The resurrected record carried the transcript, summary,
  tags and search index; `updated_at` sat 6 seconds after the purge, which is what gave it away.
  Mock mode runs ingestion inline inside the create request, so offline there is no window and all
  349 tests passed over it. Fixed by making `update_recording` **non-creating** (Firestore `update`,
  not `set` — atomic, where a `get`-then-`set` guard would only shrink the race), turning a `None`
  return into the existing `RecordingNotFound`, and discarding chunks the losing run had written.
  Covers at-least-once redelivery for free, since the push handler already acks that exception.
  7 tests, each verified to fail without the guard. **Deployed** — in every image since `api:v13`,
  and production runs `v15`. The fix has not been re-checked against production the way the bug was
  found
- [ ] Retrieval / prompt tuning
- [ ] Optional end-to-end encryption tier
- [x] **Real accounts, one device at a time, and sign-out** (2026-08-22) — the deferred
  switch-accounts feature, delivered by removing the thing that blocked it rather than working
  around it. Identity is no longer the phone: `POST /auth/otp/verify` resolves a verified address to
  a **permanent server-issued uid** and `POST /auth/session` mints a Firebase **custom token** for
  it, so every device signing into one email authenticates as one account. `merge_user` is gone from
  both repositories, along with the stats lineage it needed — and with it the orphaned-audio bug,
  since an account id that never moves cannot strand blobs under an old storage prefix.
  An account holds one `DeviceSession`; `require_live_session` gates every app-facing router and
  refuses a superseded device with a structured 401 naming the device and time that replaced it (the
  WS closes with 4403). Login is two steps so the second device can *ask* before signing the first
  one out. `POST /auth/logout` plus a Sign out button is what makes one phone serve several people.
  Login is now the app's gate — no anonymous browsing. 43 backend tests over the flows, 10 widget
  tests over the screen; 352 + 138 green. **Breaking**: any installed build stops working against
  this backend, so app and backend ship together
- [x] **One session per surface, not per account** (2026-10-03) — an account now holds one session
  on **mobile** and one on **web**, so typing a memory on a laptop no longer signs the phone out.
  Between two phones the rule is unchanged. The surface comes from the reported platform and anything
  that is not a browser is mobile, so an unrecognised client cannot mint a third session; the request
  gate matches the session id against both slots rather than trusting `X-Platform`, and logout clears
  only the slot the presented id is in. `sessions/{uid}` became a map of surface to session, with old
  bare documents read in place, so the deploy signed nobody out

---

## Phase 3.5 — Operations & launch surface

- [x] **Renamed the product to MemoriesIQ** — launcher label, in-app title, onboarding copy, web
  title/manifest, pubspec description, and the `MemoriesIQApp` widget. `AppConfig.appName` is now the
  single source. VoiceIQ deliberately stays as the internal name for the backend, the `VOICEIQ_` env
  prefix, the Dart package, and every GCP resource
- [x] **Android application id** → `com.memoriesiq.app` (was `com.example.voiceiq`, which the Play
  Store rejects outright). The package is registered in Firebase and `google-services.json` +
  `firebase_options.dart` are regenerated. Note `flutterfire configure` **crashes** on this project —
  it resolves to CLI 0.1.1+2, which casts the web app's absent `measurementId` to a non-nullable
  String, and 1.x won't resolve (`pub_updater ^0.5.0`). Use `firebase apps:sdkconfig` instead
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
- [x] **Premium/free tier** — admin-set flag with an audit trail, and now **five real
  entitlements**, all in `core/entitlements.py` and all read from `userStats`, which no client can
  write, so none can be self-granted:

  | Limit | Free | Premium | Setting |
  | --- | --- | --- | --- |
  | Voice memories per month | 10 | 100 | `VOICEIQ_RECORDINGS_PER_MONTH_*` |
  | One recording | 60 s | 600 s | `VOICEIQ_RECORDING_MAX_SECONDS_*` |
  | One spoken conversation | 600 s | 3600 s | `VOICEIQ_VOICE_SESSION_MAX_SECONDS_*` |
  | Typed memory length | 1,000 chars | 10,000 | `VOICEIQ_TEXT_MAX_CHARS_*` |
  | Journals | 2 | 20 | `VOICEIQ_JOURNALS_MAX_*` |

  The three voice limits meter what actually costs money per minute; **typed memories are metered by
  neither count nor time**, so the free tier stays usable as a notebook and running out of recordings
  never costs someone a moment. All five ride along on `GET /profile` so the app can refuse *before*
  the microphone opens — a 429 after the upload means the user spoke for nothing. The monthly counter
  is `usage_month` + `voice_recordings_this_month` on `userStats`, deliberately not refunded on
  delete. Every limit is gated on **creation only**, so a downgrade is never destructive. There is
  still **no purchase flow** — premium is granted by an admin in the console — so the caps show plain
  counters and no upsell
- [x] **Marketing site** (`site/`) — static HTML for ad traffic, plus the privacy policy the Play
  listing requires. Legal copy complete: NativeMinds AI Solutions LLC, WA, USA, `info@nativemindsai.com`
- [x] **Firebase Hosting** — one target (`admin`) in `firebase.json` + `.firebaserc`;
  `firebasehosting.googleapis.com` enabled in Terraform. The `site` target was dropped when the
  marketing page moved to Azure, because CI deploys every hosting target and would have republished
  a stale copy. The Firebase site `memoriesiq-site` still exists (seen in `firebase
  hosting:sites:list`, 2026-10-04) and can be deleted
- [x] **Firebase web app registered + Google sign-in enabled**; admin console deployed to
  `https://memoriesiq-admin.web.app` with the allowlist set on Cloud Run
- [x] ~~Run the stats backfill~~ — **not required.** The script
  (`backend/scripts/backfill_user_stats.py`) is kept for the case where pre-`userStats` accounts ever
  need reconstructing, but the existing accounts are throwaway test identities not worth importing
- [x] **Publish the marketing site** (2026-08-22) — live at `https://memoriesiq.nativemindsai.com`,
  on an Azure Static Web App beside the company site rather than on Firebase Hosting: the domain's
  DNS zone is already in Azure, and a subdomain of a site people already trust is a better landing
  page for paid clicks than a bare new domain. The backend stays on GCP. Canonical URLs were fixed
  to point here instead of `memoriesiq.com`, which does not resolve. Since 2026-10-03 the header and
  hero link into the web app, and the stylesheet is `styles.v5.css` (CSS is served immutable for a
  year, so a change needs a new name)
- [ ] **Lawyer's sign-off on the terms** — the site went out without it. Two values in
  `site/terms.html` were *inferred*, not given — the governing jurisdiction (**State of Washington**,
  from the registered address) and the liability cap (**US$100**, a floor because the app is free, so
  "the amount you paid us" is $0; a literal $0 cap can be void as illusory in some jurisdictions and
  would take the whole clause with it). Three clauses were added on 2026-10-03 and are equally
  unreviewed: the service may stop for any reason, memories can be lost to technical failure without
  liability, and any account may be closed at any time without notice. All of it wants confirming
  before the site takes paid traffic
- [x] **The app in a browser** (2026-10-03) — the Flutter web build is live at
  `https://app.memoriesiq.nativemindsai.com`, an Azure Static Web App. Three things stood between
  compiling and being usable: the install id, session and theme were files under `path_provider`
  (no web implementation, so every refresh signed the tab out) and now go through `LocalStore`;
  spoken recall needed a Web Audio player; and playback discarded the server's `Content-Type`, so a
  memory recorded in a browser (webm) reached a phone as `audio/mp4`. The static-site config allows
  the microphone for its own origin and serves Flutter's entry points `no-cache`
- [x] **Wide-screen layout** (2026-10-03) — at 1100px and wider the app is a slim rail and a page,
  with Record and Recall as the two large actions on Home. "More" became "Settings", laid out as a
  list of sections with the chosen one beside it. A narrower window is still exactly the phone layout
- [x] **Sign-in asks for the email alone** (2026-10-03) — the name is asked for after the code, and
  only when the account has none; the server fills a blank and never overwrites. The screen now says
  that signing in agrees to the terms and privacy policy, and links to both. `MOCK_AUTH=true` and
  `VOICEIQ_MOCK_OTP_CODE` make signing in against the mock backend possible again
- [x] **Admin console: user page and plan control** (2026-10-03) — opening a user rendered nothing,
  because the page read `previous_uids.length`, a list the API stopped sending when account merging
  was removed. Fixed, with an error boundary so the next such bug says what happened. The tier
  control is now a Plan section with a confirmed "Upgrade to Pro"
- [~] **Decide what premium actually unlocks** — five things now (see the tier entry above). The
  three voice limits are the ones with a cost story behind them: transcription, enrichment and a live
  Gemini socket all bill per minute, so what premium sells there is *more of the expensive thing*
  rather than a bigger number. Journals remain the strongest non-cost lever, because what they buy is
  **scoped recall**. All five are ceilings rather than walls, enforced on *creation only*, so a lapsed
  subscription never strands anything. The product question left is whether this is enough to charge
  for; a purchase flow does not exist, so premium remains admin-granted

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

- [ ] Android **release** readiness — the real blocker to shipping. Done: HTTPS backend, a Play-legal
  application id (`com.memoriesiq.app`), launcher label, and the **launcher icon** — "Rings", an
  adaptive icon with a themed-icon monochrome layer plus legacy mipmaps for API 23–25, all generated
  from `tools/branding/generate_icons.py`. **Outstanding: app signing** (release builds still use the
  debug keystore, per `app/android/app/build.gradle.kts`) and the Play listing itself. The
  privacy-policy URL the listing needs now exists: `https://memoriesiq.nativemindsai.com/privacy.html`
- [ ] **Merge `tier-limits-and-deletion` into `main`** — 21 commits, all but the last two deployed to production but never
  merged and never run through CI, which only triggers on `main` pushes and pull requests. `main`'s
  own last run is red. Two ruff findings in `tests/test_otp_mock_code.py` have to go first
- [x] **The ingest subscription expired and took ingestion with it** (2026-10-03) — new recordings
  sat at "transcribing" forever. A Pub/Sub subscription with no expiration policy is deleted after
  31 days without activity, and publishing to a topic nobody subscribes to succeeds and delivers
  nothing, so nothing failed loudly. `expiration_policy { ttl = "" }` in `infra/main.tf` means never
  expire; applied, and `voiceiq-ingest-worker` is back with no expiry (checked 2026-10-04)
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
- [x] **Secrets split out of the public repo** — the GitHub repository is **public**, and
  `infra/terraform.tfvars` was about to gain `admin_emails`, which names the exact account worth
  attacking to reach the console. `billing_account` and `admin_emails` now live in a gitignored
  `infra/secrets.auto.tfvars` (Terraform auto-loads it; `plan` confirms no drift). Also gitignored:
  `infra/tfplan` (a saved plan embeds every resolved variable value) and `.firebase/` deploy caches.
  **Note the billing account remains in git history** from an earlier commit — not directly
  exploitable without IAM access, but it is public
- [ ] Cross-lingual recall unverified — the multilingual embedder is the load-bearing choice for the
  target users (Tamil/Hindi memories, English questions) and has never been tested with non-English
  audio. Needs a real non-English recording through the live pipeline
- [ ] Restrict the Firebase **web** API key — now committed and public (normal for Firebase, which
  treats it as a client identifier), but it should carry HTTP-referrer restrictions in the GCP
  console so it only works from the console's own origin

---

## Progress snapshot

| Phase | Done | Partial (mock) | Not started |
|-------|:----:|:--------------:|:-----------:|
| 0 — Foundations | 7 | 0 | 1 |
| 1 — MVP | 13 | 1 | 0 |
| 2 — Enrichment | 0 | 2 | 3 |
| 3 — Scale & polish | 4 | 1 | 4 |
| 3.5 — Operations & launch | 16 | 1 | 1 |
| 4 — Cost optimization | 0 | 0 | 7 |
| Cross-cutting | 8 | 0 | 5 |

## Maintaining this doc

- Flip a box (`[ ]` → `[~]` → `[x]`) as work lands, and refresh **Last updated** + the snapshot table.
- Promote a `[~]` to `[x]` only once the **real (non-mock) path** is exercised, not just the mock.
- Add new major work as a checklist item under the phase it belongs to; keep one line per item.
