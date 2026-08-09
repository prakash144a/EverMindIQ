# VoiceIQ Infrastructure (Terraform)

Provisions the Google Cloud footprint for VoiceIQ.

## What it creates

- Enabled APIs (Run, Firestore, Storage, Pub/Sub, KMS, Secret Manager, Vertex AI, Firebase).
- **CMEK**: a KMS key ring + `audio` key (90-day rotation) and the GCS↔KMS IAM binding.
- **Encrypted audio bucket**: uniform access, public access prevented, CMEK default key, CORS for
  signed-URL uploads.
- **Firestore** native database.
- **Pub/Sub** ingestion topic + push subscription to the backend worker endpoint.
- **Backend service account** with least-privilege roles (Firestore, Storage, Pub/Sub, Vertex AI,
  Secret Manager, KMS).
- **Secret Manager** secret for app config.
- **Cloud Run** service running the backend in real mode.

## Usage

```bash
cd infra
terraform init
terraform apply \
  -var="project_id=YOUR_PROJECT" \
  -var="region=us-central1" \
  -var="audio_bucket_name=voiceiq-audio-YOUR_PROJECT"
```

Then deploy the backend image (CI does this on push to main) and re-apply with
`-var="container_image=REGION-docker.pkg.dev/PROJECT/voiceiq/api:TAG"`.

## Firestore rules & indexes

Deploy from the repo root with the Firebase CLI:

```bash
firebase deploy --only firestore:rules,firestore:indexes
```

- `firestore.rules` — owner-only access to `users/{uid}/**`.
- `firestore.indexes.json` — recording ordering indexes + the **vector index** on `chunks.embedding`
  (dimension must match `VOICEIQ_EMBEDDING_DIM`).

## Notes

- Keep `region` co-located with Gemini for Live latency.
- The Cloud Run push subscription targets `/internal/ingest`; add that authenticated worker route to
  the backend when moving off inline (mock) ingestion.
