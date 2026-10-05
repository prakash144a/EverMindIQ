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
| `core/security`   | Firebase ID-token verification → `CurrentUser`; the one-device session gate. |
| `services/identity` | Permanent account ids, session ids, and the custom token a device signs in with. |
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
                                    notificationsEnabled, answerLanguage, summaryLanguage,
                                    retentionDays }

users/{uid}/recordings/{recordingId}
  eventDate, recordedAt, source (voice|text), audioPath, durationSec, status,
  journalId (empty = unfiled),
  transcript (original language), transcriptEdited, language, transcriptEn (optional),
  title, summary, tags[], people[], places[], mood, isMilestone, createdAt, updatedAt

users/{uid}/recordings/{recordingId}/chunks/{chunkId}
  text, startSec, endSec, embedding (vector)

users/{uid}/journals/{journalId}   name, colorIndex, createdAt, updatedAt

users/{uid}/insights/{insightId}   range, from, to, summary, themes[], generatedAt
users/{uid}/memoryFeed/{yyyy-mm-dd} items[]
```

Per-user subcollections give natural isolation: security rules require `request.auth.uid == uid`.

`journalId` is denormalized onto the recording rather than the journal holding a list of members:
filtering is a scan either way, and a list would have to be rewritten on every capture. A journal
**name** is user-authored content — "Therapy", "Divorce", "Baby" describe a
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

**Editing a memory** (`PATCH /recordings/{id}`) follows one rule: the user owns the title and the
words, the AI owns everything derived from the words. So `title` is a plain field write with no model
call, and from then on ingestion leaves it alone (it only ever fills in a missing title). There is no
`summary` field to write. A changed `transcript` clears what was derived from the old one (summary,
tags, people, places, mood, language, English copy), drops the memory's chunks, sets
`status=uploaded` and re-enqueues ingestion, which costs one enrichment call and one embedding call
and writes a new summary and a new set of vectors — the title is kept because it exists. The chunks
are dropped at edit time rather than left to be overwritten, so recall can never answer from words
the user has removed, even if the re-run is slow or fails. `transcriptEdited` makes ingestion treat
the stored transcript as the source of truth for a spoken memory too, so a redelivered Pub/Sub
message cannot transcribe the audio back over a correction. A rename or a rewrite also purges the
On This Day and insight caches, both of which copy titles and summaries. Title and words are refused
with a 409 while a run is in flight, because that run writes the whole document back. The typed-memory
cap applies to the new length, except that a memory already over it may be edited at its current size.

`POST /recordings/{id}/title` asks the AI for a **new title**: the way back from a mistaken rename,
and the way on from an AI title nobody liked. It is one small model call, made in the request, that
passes the current title as the one to avoid and writes in `settings.summaryLanguage`. Nothing else
is touched — the words are unchanged, so the summary and the vectors are still right.

All three — rename, rewrite, new title — are open only inside the **edit window**:
`memory_edit_window_days` (7) from `recordedAt`, the moment of capture, not `eventDate`, so a
back-dated memory is still editable on the day it is written. After that the API answers 403
`edit_window_closed`. The number is published on `GET /profile` as `edit_window_days` so the app can
disable the controls rather than discover the rule from an error. It is the same for every tier.
Starring, filing and deleting are organising rather than editing, and are never closed by it.

**Journals** are named containers the user files memories into, one per memory. Filing is manual:
chosen on the record screen, changed later from the memory detail view. Nothing files on the user's
behalf, so the enrichment prompt is untouched. Count is the **entitlement** — free keeps 2, premium
20 (`core/entitlements`) — and the gate is on *creation only*: an existing journal can always be
listed, renamed, filed into and deleted, so a lapsed subscription can never strand memories inside
containers their owner may no longer touch.

**RAG:** embed query → vector search (top-k, filtered by `uid` + optional date range + optional
journal) → assemble context → Gemini answers with citations back to recordings/dates.

**Voice entitlements** are the three that meter the parts that cost money per minute, all in
`core/entitlements` and all read from the same server-only `userStats` document:

| Limit | Free | Premium | Enforced at |
| --- | --- | --- | --- |
| Voice memories per calendar month | 10 | 100 | `POST /recordings` → 429 |
| One recording | 60 s | 600 s | `POST /recordings` → 413 |
| One spoken recall conversation | 600 s | 3600 s | `services/live` hangs up the session |

Typed memories are metered by *neither* count nor length-in-time — writing costs nothing to
transcribe, so the only lever on it is `text_max_chars`. The monthly counter lives on `userStats` as
`usage_month` + `voice_recordings_this_month`: one counter stamped with the month it belongs to, so
roll-over is a comparison rather than a cleanup job, and a stale stamp reads as zero. It is
deliberately **not** decremented on delete — the transcription was already paid for, and refunding
the slot would make the quota bypassable by recording, keeping the transcript, and deleting.

Every one of these is *also* published on `GET /profile`, because the app has to refuse before it
opens the microphone: a 429 that arrives after the upload means the user spoke for nothing. The
server checks remain the backstop, never the primary gate.

The conversation limit is per call, not per month, and it is enforced inside the session object
rather than the router: what it protects is an open Gemini Live socket, which bills for as long as it
is held, whatever the client does. It announces itself in the `ready` frame (`limit_sec`) and ends
with its own `limit_reached` frame rather than an `error` — running out of time you were told you had
is the plan working.

**Scoped recall** is the point of journals: asking about one answers from it alone. Scope is set two
ways — the picker in Recall, and detection when the question names one of the user's own journals
(`pipeline/journal_scope`, a word match over those names, deliberately not a second model call). The
request field is three-state: absent means "infer if you can", `""` means the user explicitly asked
across everything, an id scopes. The answer echoes the journal it used, because a search narrowed
without saying so reads as a search that missed things; a scoped miss names the journal rather than
claiming nothing was ever recorded.

**Cross-lingual:** transcripts stored in original language; a **multilingual** embedding model maps
meaning across languages, so an English question retrieves Tamil/Hindi/French memories with no
query-time translation. Answers follow the question's language or `settings.answerLanguage`. A
memory's title and summary follow `settings.summaryLanguage` instead: `memory` (the default) writes
them in the memory's own language, a language code writes them in that language whatever the memory
is in. It is a separate setting because `answerLanguage`'s `auto` means "match my question", and a
saved memory has no question.

**Insights:** fetch range → map-reduce summarize → extract themes → cache. Long ranges precomputed
nightly. **On This Day:** nightly job writes `memoryFeed/{today}` from anniversaries + milestones.

**Live voice:** the app opens WSS to `/live`, sends `{"type":"audio_start"}`, then streams raw
microphone PCM (16 kHz mono, PCM16) as binary frames; Gemini's own voice comes back as binary PCM
(24 kHz mono) plus JSON control frames — `input_transcript`, `output_transcript`, `citations`,
`interrupted`, `turn_complete`. Binary is audio and JSON is control, both directions. Nothing on the
device recognizes or synthesizes speech, which is what makes voice work in the language the memories
are actually in. Memories reach the model as a **tool** (`recall_memories`) rather than as context
stuffed in up front, because a spoken conversation has no single question to retrieve for; the tool
runs the same `pipeline.rag.retrieve` the text Recall screen uses, and whatever it returns is also
sent to the client as citations. The same socket still carries the text protocol, so ending a call
does not end the chat. Keys never leave the server.

A conversation is many turns on one session, and the SDK does not hand it over that way: its
`session.receive()` generator covers a **single** model turn and returns at `turn_complete`.
Iterating it once answers the first question and then goes silent with the microphone still
streaming up, so the bridge re-enters it in a loop and treats a turn that yields nothing at all as
the socket having gone. The two directions run as separate tasks and the first one to finish ends
the call, rather than leaving the survivor holding an open (billing) session. On the client, a
**mute** button withholds the microphone during an answer: echo cancellation stops the model hearing
itself, but not a television or a passing conversation, and either counts as a barge-in that cuts
the answer off. Muted frames are dropped on the device rather than pausing the recorder, so
unmuting is instant.

## 6. Security

TLS everywhere; Firebase ID token verified per request; App Check. Audio in GCS with CMEK, no public
objects, uploads via short-lived signed URLs. Firestore rules scope every doc to its owner. Gemini
calls are server-side only; keys in Secret Manager.

**Deletion** is total in both sizes, and the app says so in those words, so the implementation has to
earn the sentence. Deleting one memory removes its document, its chunks (which *are* the search
index), its audio object, and the **derived caches** — `feeds` and `insights`. That last one is not
obvious and is the reason `Repository.purge_derived` exists: a feed item copies the title and summary
out of the recording it was built from and is served from storage rather than recomputed, so without
the purge a deleted memory goes on being shown to the person who deleted it. The caches are dropped
wholesale rather than edited, because both are rebuilt on demand and a missed entry is exactly the
failure the feature exists to prevent. Deleting an account does all of that plus journals, feedback,
settings, `userStats`, the device links and the email index, and sweeps storage **by prefix** so
blobs whose recording was never registered go too. Nothing is archived on the way out; there is no
recovery path to offer, and the app does not pretend otherwise.

**A delete must beat a slow writer.** Ingestion is a read-modify-write with *seconds* in the middle
(a Pub/Sub hop, then Gemini), and a delete landing in that window used to be silently undone: the
worker's final write re-created the document, transcript, summary and search index included. Found
on production on 2026-08-19, invisible offline because mock mode runs ingestion **inline** inside the
create request, so there is no window to lose.

The invariant that fixes it, and that new code must not break: **`update_recording` never creates.**
`add_recording` is the only way a recording comes into being. Firestore uses `update` rather than
`set` — one atomic operation that fails when the document is absent, where a `get`-then-`set` guard
would only shrink the race. A `None` return means the memory was deleted underneath the caller, and
`pipeline.ingest._write_or_gone` turns that into `RecordingNotFound`, discarding any chunks the run
had already written (they hold the transcript, so leaving them leaves the thing the delete promised
to remove). `PATCH /recordings/{id}` is the same shape on a shorter fuse and answers 404.

Raising `RecordingNotFound` is also what makes at-least-once delivery safe. The ingest subscription
has a retry policy and no dead-letter queue, so the same message can arrive days later; the push
handler acks that exception instead of retrying against nothing. This is why gating the *client's*
delete button on `status == indexed` would not have worked — a redelivery arrives long after the
memory is indexed, a run exceeding the 120s ack deadline gets redelivered while still running, and
memories stuck in `failed`/`transcribing` would have become permanently undeletable.

## 7. Admin plane

The console (`admin/`) is a static React SPA that talks only to `/admin/*` on the same backend. It
cannot read Firestore directly: the client rules deny everything outside `users/{uid}`, so a
cross-tenant read is impossible from a browser by construction.

**Authorization.** An allowlist in settings (`VOICEIQ_ADMIN_UIDS`, `VOICEIQ_ADMIN_EMAILS`), checked
by `require_admin` as a router-level dependency so no endpoint can ship unguarded. An empty
allowlist denies everyone. Email entries require `email_verified` on the token — Firebase's
email/password provider issues tokens for unverified addresses, so without that check an allowlisted
address could be claimed by anyone who registers it. Admins sign in with Google; app users sign in
with a code to an inbox, and hold uids the server issues, so neither an address nor a uid can be
claimed into the allowlist by registering it.

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
(`create_recording`, `delete_recording`, `create_feedback`, the login paths, `delete_user`), and totals come from Firestore aggregation queries. `max_duration_sec` is a
high-water mark — a maximum cannot be decremented without a rescan — so it means "longest ever
recorded", which is also the more useful statistic.

**Device identity.** The app generates a random install UUID on first launch, stored in a file and
sent as `X-Install-Id` alongside `X-Platform` and `X-App-Version` on every request. Not a hardware
id: it resets on reinstall and is deleted with the account. It survives sign-out — which is what
lets the console show several accounts sharing one phone, and what lets a login say "this account is
already open on *this* device, so nothing needs taking over". A per-instance cache throttles the
resulting write to roughly one per user per day.

**A uid is a stable account key.** It was not always: identity used to be the phone, a per-install
anonymous Firebase uid, so signing in on a second device *moved* the account onto it — emptying the
first, churning uids, and stranding audio under the old uid's storage prefix. See §8.

## 8. Accounts and sessions

**One email is one account, for good.** `POST /auth/otp/verify` resolves the verified address to a
permanent server-issued uid (`usr_…`, `services/identity`) or creates one, and `POST /auth/session`
mints a **Firebase custom token** for it. Every device that signs into an address authenticates as
the same uid, so a second phone is a second window onto one account — nothing is copied, moved, or
merged, and the account outlives every device that ever held it.

This replaced an identity model where the account *was* the phone: a per-install anonymous uid, with
signing in implemented as `merge_user`, which moved the whole account onto the calling device and
deleted the old one. It worked, and it cost: the first device silently went blank, uids churned, and
audio objects (keyed `users/{uid}/audio/…`) stayed behind under a uid that account deletion would
never sweep. A permanent uid removes all three, and the merge machinery with them.

**One device per surface.** An account has two *surfaces* — `mobile` and `web` — and holds one
`DeviceSession` in each (`sessions/{uid}`, server-only, a map of surface to session). The surface is
derived from the reported platform: a browser is `web`, everything else is `mobile`, including any
client we do not recognise, so an unknown platform can never mint itself a third session.

Two surfaces because a browser is the one client that is genuinely *elsewhere*: someone typing a
memory on their laptop still has their phone in their pocket, and signing that phone out to do it
would be absurd. Within a surface the rule is unchanged — a second phone displaces the first, a
second browser displaces the first — which is what still keeps a shared device from staying signed
in. Contention, the 409, and the takeover question are therefore all scoped to the caller's own
surface; a phone is never in a browser's way.

Login is two steps because of the question in the middle:

1. `POST /auth/otp/verify` checks the code and returns a short-lived single-use **ticket**, plus a
   description of the device already signed in *on this surface*, if there is one.
2. `POST /auth/session` spends the ticket. If another device holds that surface it answers **409**
   until the caller passes `takeover: true`.

The split exists so the second device can show "your account is open on an Android phone, signed in
2 hours ago" and let the person decide — by which point their code is already spent, so the ticket
is what carries the verified state across the question. Signing someone out is never a side effect
of a missing field.

**Everything else is gated.** `require_live_session` sits on every app-facing router
(`main.create_app`) and demands a live `X-Session-Id` beside the token. The id is matched against
*both* slots rather than the one `X-Platform` claims: that header is the caller's own and proves
nothing, whereas a session id is unguessable and belongs to exactly one slot. Which slot it turned
up in is used only to word a refusal. It reads the session document per request with no cache,
deliberately: a cache here is a lie with a timer on it in both
directions — the device that just took over would be refused until it expired, and the one that was
signed out would keep working. A refusal is structured, not a bare 401, because it is the **only**
moment the replaced device can be told anything:

```json
{"detail": {"code": "session_replaced", "device": "an Android phone", "signed_in_at": "…"}}
```

The app turns that into a full-screen explanation above the login form. `ApiClient` recognises it
once, centrally, so no screen has to remember to. The WebSocket checks the same thing on connect and
closes with **4403** rather than 4401, since "you were signed out" and "your login failed" are
different sentences.

**Signing out** (`POST /auth/logout`) clears the caller's own surface and nothing else — found by
the session id it presented, so closing a browser tab cannot sign a phone out. That is what makes one
phone usable by several people: the memories stay with the account, the next person signs in with
their own address, and the app invalidates every account-scoped provider so not a single row of the
previous account survives the switch.

**What this costs.** Losing access to the inbox loses the account — there is no password fallback.
And a surface holds exactly one device: a phone and a tablet still cannot both be signed in, because
both are `mobile`. Splitting further — per install, with a list of sessions someone can revoke — is
the next step if it is ever wanted, and the slot map is already the shape to grow it from.

## 9. Phased delivery

- **Phase 0** — foundations: GCP/Firebase, Terraform, app shell, CI.
- **Phase 1 (MVP)** — record + back-date, encrypted upload, ingestion, calendar, Talk-to-AI (text and live voice), auth.
- **Phase 2** — On This Day, insights drawer, push, entity extraction/search.
- **Phase 3** — Vertex Vector Search migration, milestones, export, tuning, optional E2E tier.
- **Phase 3.5** — operations & launch surface: admin console, marketing site, product rename,
  device/account tracking, tier flag.
- **Phase 4** — cost optimization, deliberately deferred until there is real traffic to measure.

Current status per item lives in [milestones.md](./milestones.md), which is the tracker; this file
describes the design.
