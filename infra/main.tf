# VoiceIQ infrastructure.
#
# Provisions: enabled APIs, a KMS key (CMEK), the encrypted audio bucket, a Firestore database,
# the Pub/Sub ingestion topic + subscription, Secret Manager, the backend service account with
# least-privilege IAM, and the Cloud Run service. Vertex AI / Gemini are used via API (no resource).

locals {
  services = [
    "run.googleapis.com",
    "firestore.googleapis.com",
    "storage.googleapis.com",
    "pubsub.googleapis.com",
    "cloudkms.googleapis.com",
    "secretmanager.googleapis.com",
    "aiplatform.googleapis.com",
    "firebase.googleapis.com",
  ]
}

resource "google_project_service" "enabled" {
  for_each           = toset(local.services)
  service            = each.value
  disable_on_destroy = false
}

# --- CMEK: key ring + key for audio-at-rest ---------------------------------
resource "google_kms_key_ring" "voiceiq" {
  name       = "voiceiq"
  location   = var.region
  depends_on = [google_project_service.enabled]
}

resource "google_kms_crypto_key" "audio" {
  name            = "audio"
  key_ring        = google_kms_key_ring.voiceiq.id
  rotation_period = "7776000s" # 90 days
  lifecycle {
    prevent_destroy = true
  }
}

# Allow the GCS service agent to use the key.
data "google_storage_project_service_account" "gcs" {}

resource "google_kms_crypto_key_iam_member" "gcs_uses_key" {
  crypto_key_id = google_kms_crypto_key.audio.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}

# --- Encrypted audio bucket -------------------------------------------------
resource "google_storage_bucket" "audio" {
  name                        = var.audio_bucket_name
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  encryption {
    default_kms_key_name = google_kms_crypto_key.audio.id
  }

  # Enforce the app's own CORS for signed-URL PUTs from the mobile clients.
  cors {
    origin          = ["*"]
    method          = ["PUT", "GET"]
    response_header = ["Content-Type"]
    max_age_seconds = 3600
  }

  depends_on = [google_kms_crypto_key_iam_member.gcs_uses_key]
}

# --- Firestore (native mode) ------------------------------------------------
resource "google_firestore_database" "default" {
  name        = "(default)"
  location_id = var.region
  type        = "FIRESTORE_NATIVE"
  depends_on  = [google_project_service.enabled]
}

# --- Pub/Sub ingestion topic + push subscription ----------------------------
resource "google_pubsub_topic" "ingest" {
  name       = "voiceiq-ingest"
  depends_on = [google_project_service.enabled]
}

resource "google_pubsub_subscription" "ingest_worker" {
  name  = "voiceiq-ingest-worker"
  topic = google_pubsub_topic.ingest.id

  ack_deadline_seconds = 120

  push_config {
    push_endpoint = "${google_cloud_run_v2_service.api.uri}/internal/ingest"
    oidc_token {
      service_account_email = google_service_account.backend.email
    }
  }
  retry_policy {
    minimum_backoff = "10s"
  }
}

# --- Backend service account + IAM (least privilege) ------------------------
resource "google_service_account" "backend" {
  account_id   = "voiceiq-backend"
  display_name = "VoiceIQ backend (Cloud Run)"
}

resource "google_project_iam_member" "backend_roles" {
  for_each = toset([
    "roles/datastore.user",              # Firestore read/write
    "roles/storage.objectAdmin",         # signed URLs + object lifecycle (scoped bucket below)
    "roles/pubsub.publisher",            # publish ingest events
    "roles/aiplatform.user",             # call Gemini / embeddings
    "roles/secretmanager.secretAccessor",
    "roles/cloudkms.cryptoKeyEncrypterDecrypter",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.backend.email}"
}

# --- Secret for the app config (e.g. model ids / API keys) ------------------
resource "google_secret_manager_secret" "app" {
  secret_id = "voiceiq-app"
  replication {
    auto {}
  }
  depends_on = [google_project_service.enabled]
}

# --- Cloud Run service ------------------------------------------------------
resource "google_cloud_run_v2_service" "api" {
  name     = "voiceiq-api"
  location = var.region

  template {
    service_account = google_service_account.backend.email
    containers {
      image = var.container_image
      env {
        name  = "VOICEIQ_MOCK"
        value = "0"
      }
      env {
        name  = "VOICEIQ_GCP_PROJECT"
        value = var.project_id
      }
      env {
        name  = "VOICEIQ_GCP_REGION"
        value = var.region
      }
      env {
        name  = "VOICEIQ_AUDIO_BUCKET"
        value = google_storage_bucket.audio.name
      }
      env {
        name  = "VOICEIQ_KMS_KEY"
        value = google_kms_crypto_key.audio.id
      }
    }
    scaling {
      min_instance_count = 0
      max_instance_count = 10
    }
  }
  depends_on = [google_project_service.enabled]
}
