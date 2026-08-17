# VoiceIQ infrastructure.
#
# Provisions: enabled APIs, a KMS key (CMEK), the encrypted audio bucket, a Firestore database,
# the Pub/Sub ingestion topic + subscription, Secret Manager, the backend service account with
# least-privilege IAM, and the Cloud Run service. Vertex AI / Gemini are used via API (no resource).

locals {
  services = [
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "run.googleapis.com",
    "firestore.googleapis.com",
    "storage.googleapis.com",
    "pubsub.googleapis.com",
    "cloudkms.googleapis.com",
    "secretmanager.googleapis.com",
    "aiplatform.googleapis.com",
    "firebase.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "billingbudgets.googleapis.com",
    # Serves the marketing site and the admin console as static hosting.
    "firebasehosting.googleapis.com",
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

# Project metadata (used for the budget filter, which needs the project number).
data "google_project" "this" {}

# Allow the GCS service agent to use the key.
data "google_storage_project_service_account" "gcs" {}

resource "google_kms_crypto_key_iam_member" "gcs_uses_key" {
  crypto_key_id = google_kms_crypto_key.audio.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}

# --- Artifact Registry: backend container images ----------------------------
resource "google_artifact_registry_repository" "api" {
  repository_id = "voiceiq"
  location      = var.region
  format        = "DOCKER"
  description   = "VoiceIQ backend container images."
  depends_on    = [google_project_service.enabled]
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
    "roles/datastore.user",      # Firestore read/write
    "roles/storage.objectAdmin", # signed URLs + object lifecycle (scoped bucket below)
    "roles/pubsub.publisher",    # publish ingest events
    "roles/aiplatform.user",     # call Gemini / embeddings
    "roles/secretmanager.secretAccessor",
    "roles/cloudkms.cryptoKeyEncrypterDecrypter",
    "roles/firebaseauth.viewer", # verify_id_token(check_revoked=True) looks up the user record
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.backend.email}"
}

# Let the backend sign its own V4 signed URLs via the IAM signBlob API. On
# Cloud Run the runtime credentials have no private key, so generate_signed_url
# must call iam.serviceAccounts.signBlob on this SA itself.
resource "google_service_account_iam_member" "backend_token_creator" {
  service_account_id = google_service_account.backend.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.backend.email}"
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
      # Pin the Firebase project so verify_id_token validates token aud/iss
      # instead of relying on metadata auto-discovery. Same project as GCP.
      env {
        name  = "VOICEIQ_FIREBASE_PROJECT"
        value = var.project_id
      }
      # Model slots. Pinned to concrete GA ids that exist on Vertex in this
      # region ("-latest" aliases 404 there). The embedder is forced to the
      # 256-d Firestore vector index width in code.
      env {
        name  = "VOICEIQ_MODEL_EMBEDDING"
        value = "text-multilingual-embedding-002"
      }
      env {
        name  = "VOICEIQ_MODEL_REASONING"
        value = "gemini-2.5-flash"
      }
      # Admin console access. Comma-separated; an empty value denies everyone,
      # which is the right default for a service that has just been deployed.
      # Email entries only match a token whose email is *verified*.
      env {
        name  = "VOICEIQ_ADMIN_UIDS"
        value = var.admin_uids
      }
      env {
        name  = "VOICEIQ_ADMIN_EMAILS"
        value = var.admin_emails
      }
      # Browser origins allowed to call the API. The mobile app is not a browser
      # and ignores CORS entirely, so this only ever affects the web console.
      env {
        name  = "VOICEIQ_CORS_ORIGINS"
        value = var.cors_origins
      }
    }
    scaling {
      min_instance_count = 0
      max_instance_count = 10
    }
  }
  depends_on = [google_project_service.enabled]
}

# Public network access: the app authenticates every request with a Firebase ID
# token, and the /internal/ingest worker route validates the Pub/Sub push OIDC
# token — so IAM is open at the edge while auth is enforced in the app layer.
# This binding also lets the Pub/Sub push subscription reach the service.
resource "google_cloud_run_v2_service_iam_member" "public_invoker" {
  name     = google_cloud_run_v2_service.api.name
  location = google_cloud_run_v2_service.api.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# --- Billing budget + alerts ------------------------------------------------
# Scoped to this project. By default, Cloud Billing emails the budget alerts to
# the billing account's admins and users (i.e. you) at each threshold below.
resource "google_billing_budget" "monthly" {
  billing_account = var.billing_account
  display_name    = "VoiceIQ monthly budget"

  budget_filter {
    projects               = ["projects/${data.google_project.this.number}"]
    calendar_period        = "MONTH"
    credit_types_treatment = "INCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.monthly_budget_usd)
    }
  }

  # Actual-spend alerts at 10% / 40% / 80% / 100% of the ceiling
  # (with a $50 budget: $5, $20, $40, $50).
  threshold_rules {
    threshold_percent = 0.1
    spend_basis       = "CURRENT_SPEND"
  }
  threshold_rules {
    threshold_percent = 0.4
    spend_basis       = "CURRENT_SPEND"
  }
  threshold_rules {
    threshold_percent = 0.8
    spend_basis       = "CURRENT_SPEND"
  }
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "CURRENT_SPEND"
  }
  # Early warning: forecast to exceed the ceiling this month.
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  depends_on = [google_project_service.enabled]
}
