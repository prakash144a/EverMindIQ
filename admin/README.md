# MemoriesIQ Admin

Operator console. React + Vite + TypeScript, talking only to the backend's `/admin` API.

## Two things to know before changing anything

**It never sees anyone's memories.** No admin endpoint returns a transcript, summary, title, tag,
person, place, or audio file, and the response models on the server have no fields for them. That is
a hard rule, not a setting — see the module docstring on `backend/app/api/routers/admin.py` and the
guards in `backend/tests/test_admin_privacy.py`. If a dashboard would look nicer with a recording
title in it, the answer is still no.

**It cannot read Firestore directly.** `firestore.rules` denies every client anything outside
`users/{uid}`, so cross-user reads are impossible from a browser by design. Everything goes through
the backend, which uses the Admin SDK and checks the allowlist first.

## Running it

```bash
cd admin
npm install
cp .env.example .env.local     # then fill it in
npm run dev                    # http://localhost:5173
```

Against a local backend in mock mode, `/admin` will reject you: mock mode still enforces the
allowlist (deliberately — otherwise the rejection tests would be meaningless). Start the backend
with an allowlisted uid and sign in as it:

```bash
cd backend
VOICEIQ_ADMIN_UIDS=root-admin uvicorn app.main:app --reload
```

## Getting in

Two prerequisites, both one-off and both done in the Firebase console for project `voiceiq-505205`:

1. **Register a web app.** The project currently has an Android registration only, so there is no
   web API key or app id yet. Registering one produces the four `VITE_FIREBASE_*` values.
2. **Enable the Google sign-in provider.** Only Anonymous is enabled today. Google specifically,
   because the backend requires `email_verified` on the token — Firebase's email/password provider
   will issue a token for any address the caller types, so allowlisting an email would otherwise be
   bypassable by anyone who registers it.

Then add yourself to `VOICEIQ_ADMIN_EMAILS` (or `VOICEIQ_ADMIN_UIDS`) on the Cloud Run service, via
`admin_emails` in `infra/terraform.tfvars`. An empty allowlist denies everyone, which is the
intended default.

## Layout

```
src/
├── api.ts          fetch wrapper; attaches a fresh Firebase ID token per call
├── auth.ts         Google sign-in
├── router.ts       hash routing, ~25 lines — seven pages do not need a router dep
├── types.ts        mirrors backend/app/models/admin.py
├── components.tsx  formatting, stat tiles, async loading
└── pages/          Overview · Users · UserDetail · Devices · Feedback · Health
```

Do not create `src/lib/` — the repo's root `.gitignore` is the Python template, which ignores `lib/`
everywhere, and git would silently drop the folder. `src/utils/` is fine.

## Commands

| | |
|---|---|
| `npm run dev` | dev server on 5173 |
| `npm run typecheck` | `tsc --noEmit` |
| `npm run build` | typecheck, then production build into `dist/` |
| `npm run preview` | serve the built bundle |

CI runs typecheck and build on every push. Deployment goes to Firebase Hosting target `admin`.
