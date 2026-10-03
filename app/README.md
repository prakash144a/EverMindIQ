# MemoriesIQ App (Flutter)

Flutter client for iOS + Android: Record, Talk-to-AI, Home (On This Day), Calendar, Insights.

The product name is **MemoriesIQ** — that is what users see. The Dart package is still `voiceiq`
and the backend is still VoiceIQ, deliberately: those are internal names, and renaming them would
churn every `package:voiceiq/...` import for nothing a user would notice. `AppConfig.appName` is the
one place the display name lives.

## First-time setup

This repo contains `lib/`, `pubspec.yaml`, and tests. Generate the native platform folders once:

```bash
cd app
flutter create .            # creates android/, ios/, etc. without overwriting lib/
flutter pub get
```

Then add microphone permissions:

- **Android** — in `android/app/src/main/AndroidManifest.xml`:
  ```xml
  <uses-permission android:name="android.permission.RECORD_AUDIO"/>
  <uses-permission android:name="android.permission.INTERNET"/>
  ```
- **iOS** — in `ios/Runner/Info.plist`:
  ```xml
  <key>NSMicrophoneUsageDescription</key>
  <string>MemoriesIQ records your voice memories.</string>
  ```

## Run against the backend

Start the backend (see `../backend/README.md`), then:

```bash
# Android emulator reaches host localhost via 10.0.2.2
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000 --dart-define=DEV_UID=alice

# iOS simulator / desktop
flutter run --dart-define=API_BASE_URL=http://localhost:8000 --dart-define=DEV_UID=alice
```

`DEV_UID` is a placeholder auth token used until Firebase Auth is wired (see Roadmap). The backend in
mock mode treats it as the user id.

## The web app

The same Flutter code, built for the browser and served at <https://app.memoriesiq.nativemindsai.com>
from **Azure Static Web Apps** (`memoriesiq-app`, resource group `rg-nativemindsai-web`) — beside the
marketing site, which is its own Static Web App at the parent domain. The backend stays on GCP; the
web origin is named in `cors_origins` (`infra/terraform.tfvars`) so the browser may call it.

A browser signs into the account's **web** session slot, so it runs alongside the phone rather than
signing it out (`docs/architecture.md`, "One device per surface").

```bash
cd app
flutter build web --release   --dart-define=API_BASE_URL=https://voiceiq-api-fv2se2zeza-uc.a.run.app   --dart-define=APP_VERSION=web

TOKEN=$(az staticwebapp secrets list --name memoriesiq-app   --resource-group rg-nativemindsai-web --query "properties.apiKey" -o tsv)
npx --yes @azure/static-web-apps-cli deploy ./build/web --deployment-token "$TOKEN" --env production
```

`web/staticwebapp.config.json` is copied into the build and carries the headers. Two things in it
are load-bearing:

- `Permissions-Policy: microphone=(self)`. The marketing site sends `microphone=()`, which switches
  the microphone off outright — copy that config here and recording silently stops working.
- `Cache-Control: no-cache` on everything but `canvaskit/` and `icons/`. Flutter's entry points
  (`main.dart.js`, `flutter_bootstrap.js`, the asset manifests) keep the same names across builds,
  so caching them hard leaves people on an old build after a deploy.

Never pass `MOCK_AUTH=true` to a build that is deployed: it is for the local mock backend only.

## Structure

```
lib/
├── main.dart
└── src/
    ├── app.dart                 # MaterialApp + theme
    ├── core/                    # config (dart-define), theme
    ├── data/                    # models, ApiClient, Riverpod providers
    └── features/
        ├── shell/               # bottom bar + Record FAB + Insights drawer
        ├── home/                # On This Day slideshow + recent moments
        ├── calendar/            # month view + per-day recordings
        ├── record/              # record sheet (with back-date)
        ├── talk/                # Talk-to-AI over the /live WebSocket
        ├── insights/            # range picker + insight detail
        └── settings/            # toggles, answer language
```

## Roadmap (client)

- Wire **Firebase Auth** (Google/Apple/email) and send real ID tokens instead of `DEV_UID`.
- Stream **voice** over the `/live` channel (Gemini Live audio) — transport is already in place.
- Offline capture queue (Isar/Drift) with retryable uploads.
- Audio playback on recording detail (audioplayers).
