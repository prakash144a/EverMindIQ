# VoiceIQ — Architecture

> The product is called **MemoriesIQ**. **VoiceIQ** is the internal name and is what this document
> uses for the service, the `VOICEIQ_` env prefix, and every GCP resource. See the README.

## 1. Overview

VoiceIQ captures life moments — spoken or typed — indexes them for semantic search, and lets the
user converse with an AI that recalls and reasons across those memories. Two hero actions: **Record**
and **Talk to AI**. Plus **Home** (On This Day slideshow), **Calendar**, and **Insights**.

Voice is the primary path; the capture screen also takes typed text, because the moment a memory is
worth keeping is often a moment you cannot speak out loud. Both kinds land in one collection and are
indexed identically.

- **Client:** Flutter (iOS + Android).
- **Cloud + AI:** Google Cloud + Firebase, using Gemini (native Gemini Live for real-time voice).
- **Privacy:** Server-side encryption + cloud AI. Audio encrypted at rest (CMEK); server transcribes,
  embeds, and runs Gemini RAG.

## 2. System diagram

```
Flutter app ── HTTPS (REST + signed upload URLs) ──► FastAPI on Cloud Run
            └─ WSS (Live) ─────────────────────────► /live proxy ─► Gemini Live
Firebase Auth ID token on every call; App Check gates non-app clients.

Cloud Run API ──► Firestore        (recording metadata, transcripts, settings, feeds, insights)
              ──► Cloud Storage     (encrypted audio, CMEK)
              ──► Vertex AI / Gemini (reasoning, embeddings)
              ──► Pub/Sub ──► ingestion worker (transcribe→summarize→chunk→embed→index)
Cloud Scheduler ──► nightly "On This Day" + long-range insight precompute
Cloud KMS (CMEK) • Secret Manager • Cloud Logging/Trace
```

## 3. Backend modules (`backend/app`)

| Module            | Responsibility                                                        |
|-------------------|-----------------------------------------------------------------------|
| `core/config`     | Settings from env / Secret Manager; three swappable model slots.       |
| `core/security`   | Firebase ID-token verification → `CurrentUser`; per-user scoping.      |
| `models`          | Pydantic schemas (Recording, Chunk, Insight, MemoryFeed, chat DTOs).   |
| `services/firestore` | Per-user document repository (isolation by `uid`).                 |
| `services/storage`   | GCS signed upload/download URLs (CMEK bucket).                      |
| `services/gemini`    | Transcription, summary/entity extraction, RAG generation, embeddings.|
| `pipeline/ingest` | Async worker: transcribe → enrich → chunk → embed → index.            |
| `pipeline/rag`    | Query embed → vector search → grounded answer with citations.         |
| `pipeline/insights` | Range fetch → map-reduce summarize → cache.                         |
| `api/routers`     | recordings, uploads, insights, memories, chat, live (WS proxy), admin.|
| `core/activity`   | Records device + last-active from request headers, throttled per day. |
| `services/stats`  | Pure transforms on the per-user counters; shared by both repositories.|

All external services are abstracted behind interfaces with a **mock mode** (`VOICEIQ_MOCK=1`) so the
API and pipeline run and are testable without GCP credentials.

## 4. Data model (Firestore)

```
users/{uid}
  displayName, createdAt, settings{ onThisDayEnabled, slideshowInterval,
                                    notificationsEnabled, answerLanguage, retentionDays }

users/{uid}/recordings/{recordingId}
  eventDate, recordedAt, source (voice|text), audioPath, durationSec, status,
  journalId (empty = unfiled),
  transcript (original language), language, transcriptEn (optional),
  title, summary, tags[], people[], places[], mood, isMilestone, createdAt, updatedAt

users/{uid}/recordings/{recordingId}/chunks/{chunkId}
  text, startSec, endSec, embedding (vector)

users/{uid}/journals/{journalId}   name, colorIndex, createdAt, updatedAt

users/{uid}/insights/{insightId}   range, from, to, summary, themes[], generatedAt
users/{uid}/memoryFeed/{yyyy-mm-dd} items[]
```

Per-user subcollections give natural isolation: security rules require `request.auth.uid == uid`.

`journalId` is denormalized onto the recording rather than the journal holding a list of members:
filtering is a scan either way, and a list would have to be rewritten on every capture. It means a
merge must move journals before recordings, or a restored memory would name a container that is no
longer there. A journal **name** is user-authored content — "Therapy", "Divorce", "Baby" describe a
life without quoting a word of it — so it falls under the same admin-plane prohibition as
transcripts (§7).

## 5. Ingestion & RAG

**Ingestion (async):** upload audio (signed URL) → create doc (`status=uploaded`) → Pub/Sub →
worker: transcribe (original language) → title/summary/entities → chunk → **embed transcript** (not
raw audio) → upsert vectors → `status=indexed`.

**Typed memories** (`source=text`) skip the first stage: the text the user wrote *is* the transcript,
so there is no blob and nothing to transcribe, and ingestion joins at enrichment. Every later stage
is shared, which is what makes a written memory as recallable as a spoken one. Enrichment also
reports the detected language, since nothing upstream determined it. Length is the first real
**entitlement**: `core/entitlements` caps a typed memory by the caller's tier, read from the
server-only `userStats` document.

**Journals** are named containers the user files memories into, one per memory. Filing is manual:
chosen on the record screen, changed later from the memory detail view. Nothing files on the user's
behalf, so the enrichment prompt is untouched. Count is the **entitlement** — free keeps 2, premium
20 (`core/entitlements`) — and the gate is on *creation only*: an existing journal can always be
listed, renamed, filed into and deleted, so a lapsed subscription can never strand memories inside
containers their owner may no longer touch.

**RAG:** embed query → vector search (top-k, filtered by `uid` + optional date range + optional
journal) → assemble context → Gemini answers with citations back to recordings/dates.

**Scoped recall** is the point of journals: asking about one answers from it alone. Scope is set two
ways — the picker in Recall, and detection when the question names one of the user's own journals
(`pipeline/journal_scope`, a word match over those names, deliberately not a second model call). The
request field is three-state: absent means "infer if you can", `""` means the user explicitly asked
across everything, an id scopes. The answer echoes the journal it used, because a search narrowed
without saying so reads as a search that missed things; a scoped miss names the journal rather than
claiming nothing was ever recorded.

**Cross-lingual:** transcripts stored in original language; a **multilingual** embedding model maps
meaning across languages, so an English question retrieves Tamil/Hindi/French memories with no
query-time translation. Answers follow the question's language or `settings.answerLanguage`.

**Insights:** fetch range → map-reduce summarize → extract themes → cache. Long ranges precomputed
nightly. **On This Day:** nightly job writes `memoryFeed/{today}` from anniversaries + milestones.

**Live voice:** app opens WSS to `/live`; backend bridges to Gemini Live and injects retrieved memory
context per turn. Keys never leave the server.

## 6. Security

TLS everywhere; Firebase ID token verified per request; App Check. Audio in GCS with CMEK, no public
objects, uploads via short-lived signed URLs. Firestore rules scope every doc to its owner. Gemini
calls are server-side only; keys in Secret Manager. Account deletion purges GCS + Firestore + vectors.

## 7. Admin plane

The console (`admin/`) is a static React SPA that talks only to `/admin/*` on the same backend. It
cannot read Firestore directly: the client rules deny everything outside `users/{uid}`, so a
cross-tenant read is impossible from a browser by construction.

**Authorization.** An allowlist in settings (`VOICEIQ_ADMIN_UIDS`, `VOICEIQ_ADMIN_EMAILS`), checked
by `require_admin` as a router-level dependency so no endpoint can ship unguarded. An empty
allowlist denies everyone. Email entries require `email_verified` on the token — Firebase's
email/password provider issues tokens for unverified addresses, so without that check an allowlisted
address could be claimed by anyone who registers it. Admins sign in with Google; app users are
anonymous and carry no email, so they cannot match in principle.

**Privacy.** No `/admin` endpoint returns a transcript, translation, summary, title, tag, person,
place, mood, chunk, or audio. Those are content, or model-generated descriptions of content. The rule
is structural — the response models have no such fields — and is enforced by tests, not convention.
Feedback text is the one exception: the user wrote it to be read. Admin reads of user detail are
logged.

**Data.** Four top-level collections, all covered by the existing terminal deny in `firestore.rules`
and none of them writable by any client:

```
userStats/{uid}                       counters, tier, denormalized identity, device trail
devices/{install_id}                  one row per install
devices/{install_id}/accounts/{uid}   which accounts have used that device
dailyStats/{yyyy-mm-dd}               time-series counters + duration buckets
feedbackTriage/{id} · adminAudit/{id} triage state and an admin action log
```

`userStats` is separate from `users/{uid}` on purpose: that document is client-writable by its owner,
so a `tier` field living there could be self-granted from the app.

**Why denormalized.** Listing users with recording counts by walking each user's subcollection is
O(users × recordings) reads *per page load*. Counters are updated at write time instead
(`create_recording`, `delete_recording`, `create_feedback`, the OTP paths, `merge_user`,
`delete_user`), and totals come from Firestore aggregation queries. `max_duration_sec` is a
high-water mark — a maximum cannot be decremented without a rescan — so it means "longest ever
recorded", which is also the more useful statistic.

**Device identity.** The app generates a random install UUID on first launch, stored in a file and
sent as `X-Install-Id` alongside `X-Platform` and `X-App-Version` on every request. Not a hardware
id: it resets on reinstall and is deleted with the account. It survives sign-out, which is what lets
the console show several accounts sharing one phone once account switching ships. A per-instance
cache throttles the resulting write to roughly one per user per day.

**Identity caveat.** A uid is not a stable account key. Signing in to an existing email merges that
account onto the caller's current anonymous uid and deletes the old one, so uids churn; the verified
email is the durable identifier and `previous_uids` preserves the lineage.

## 8. Phased delivery

- **Phase 0** — foundations: GCP/Firebase, Terraform, app shell, CI.
- **Phase 1 (MVP)** — record + back-date, encrypted upload, ingestion, calendar, Talk-to-AI (text→voice), auth.
- **Phase 2** — On This Day, insights drawer, push, entity extraction/search.
- **Phase 3** — Vertex Vector Search migration, milestones, export, tuning, optional E2E tier.
- **Phase 3.5** — operations & launch surface: admin console, marketing site, product rename,
  device/account tracking, tier flag.
- **Phase 4** — cost optimization, deliberately deferred until there is real traffic to measure.

Current status per item lives in [milestones.md](./milestones.md), which is the tracker; this file
describes the design.
