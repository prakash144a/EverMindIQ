# Non-sensitive configuration. This file is committed — the repository is
# public, so anything private belongs in secrets.auto.tfvars (gitignored),
# which Terraform loads automatically alongside this one.
project_id        = "voiceiq-505205"
region            = "us-central1"
audio_bucket_name = "voiceiq-audio-voiceiq-505205"
container_image   = "us-central1-docker.pkg.dev/voiceiq-505205/voiceiq/api:v16"

# Browser origins allowed to call the API. The mobile app is not a browser and
# ignores CORS entirely; the admin console and the Flutter *web* build are not
# so lucky, and both have to be named here. The web app is served from Azure at
# app.memoriesiq.nativemindsai.com (see app/README.md). The localhost entries
# are kept so each can be run against the deployed backend: 5173 is the admin
# console's `npm run dev`, 8080 is `flutter run -d chrome --web-port=8080`.
cors_origins = "https://app.memoriesiq.nativemindsai.com,https://memoriesiq-admin.web.app,http://localhost:5173,http://localhost:8080"
