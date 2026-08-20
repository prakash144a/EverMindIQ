# Non-sensitive configuration. This file is committed — the repository is
# public, so anything private belongs in secrets.auto.tfvars (gitignored),
# which Terraform loads automatically alongside this one.
project_id        = "voiceiq-505205"
region            = "us-central1"
audio_bucket_name = "voiceiq-audio-voiceiq-505205"
container_image   = "us-central1-docker.pkg.dev/voiceiq-505205/voiceiq/api:v12"

# Browser origins allowed to call the API. The mobile app is not a browser and
# ignores CORS entirely, so this only gates the web console. localhost is kept
# so `npm run dev` works against the deployed backend.
cors_origins = "https://memoriesiq-admin.web.app,http://localhost:5173"
