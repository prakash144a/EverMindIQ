# VoiceIQ Infrastructure (Terraform)

Provisions the Google Cloud footprint for VoiceIQ.

## What it creates

- Enabled APIs (Run, Firestore, Storage, Pub/Sub, KMS, Secret Manager, Vertex AI, Firebase,
  Artifact Registry, Cloud Build).
- **Artifact Registry** Docker repo (`voiceiq`) for backend images.
- **CMEK**: a KMS key ring + `audio` key (90-day rotation) and the GCS↔KMS IAM binding.
- **Encrypted audio bucket**: uniform access, public access prevented, CMEK default key, CORS for
  signed-URL uploads.
- **Firestore** native database.
- **Pub/Sub** ingestion topic + push subscription to the backend worker endpoint.
- **Backend service account** with least-privilege roles (Firestore, Storage, Pub/Sub, Vertex AI,
  Secret Manager, KMS).
- **Secret Manager** secret for app config.
- **Cloud Run** service running the backend in real mode, with a public `run.invoker` binding
  (the app authenticates each request with a Firebase ID token; `/internal/ingest` validates the
  Pub/Sub push OIDC token).

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

### Variables are split across two files

This repository is **public**, so anything that should not be is kept out of it:

| File | Committed? | Holds |
|---|---|---|
| `terraform.tfvars` | yes | project, region, bucket, image tag, CORS origins |
| `secrets.auto.tfvars` | **no** (gitignored) | `billing_account`, `admin_emails` |

Terraform auto-loads any `*.auto.tfvars`, so `terraform apply` needs no extra flags — but after a
fresh clone you must recreate the secrets file, or `apply` will prompt for `billing_account` and the
admin allowlist will be empty (which denies everyone from `/admin`, by design).

```hcl
# infra/secrets.auto.tfvars
billing_account = "XXXXXX-XXXXXX-XXXXXX"
admin_emails    = "you@example.com"
```

`admin_emails` is kept private not because the address is a secret, but because publishing it names
the exact account worth attacking to reach the admin console.

## CI/CD (GitHub Actions)

The `deploy` job in `.github/workflows/ci.yml` builds the image to Artifact Registry, deploys Cloud
Run, and pushes Firestore rules/indexes. It runs only on `main` and only when `DEPLOY_ENABLED=true`,
so it stays green until you configure deployment. To enable:

1. Apply this Terraform so the Artifact Registry repo, Cloud Run service, and backend SA exist.
2. Configure **Workload Identity Federation** for the repo and create a deploy service account with:
   `roles/run.admin`, `roles/artifactregistry.writer`, `roles/cloudbuild.builds.editor`,
   `roles/datastore.owner` (to publish rules), and `roles/iam.serviceAccountUser` on the backend SA.
3. Repo **variables**: `DEPLOY_ENABLED=true`, `GCP_PROJECT_ID`, `GCP_REGION`.
4. Repo **secrets**: `GCP_WIF_PROVIDER` (provider resource name), `GCP_DEPLOY_SA` (deploy SA email).

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
