variable "project_id" {
  type        = string
  description = "GCP project id."
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "Primary region. Co-locate with Gemini for Live latency."
}

variable "audio_bucket_name" {
  type        = string
  description = "Globally-unique name for the encrypted audio bucket."
}

variable "container_image" {
  type        = string
  default     = "gcr.io/cloudrun/hello"
  description = "Backend container image; replaced by CI on deploy."
}

variable "billing_account" {
  type        = string
  sensitive   = true
  description = "Cloud Billing account id (e.g. 016CC6-981245-C8F3B9) that owns this project; used for the budget + alerts."
}

variable "admin_uids" {
  type        = string
  default     = ""
  description = "Comma-separated Firebase uids allowed into /admin. Empty denies everyone."
}

variable "admin_emails" {
  type        = string
  default     = ""
  description = "Comma-separated emails allowed into /admin. Only matches tokens with a VERIFIED email, so sign in with Google rather than email/password."
}

variable "cors_origins" {
  type        = string
  default     = "*"
  description = "Comma-separated browser origins allowed to call the API. The mobile app ignores CORS; this only gates the web console."
}

variable "monthly_budget_usd" {
  type        = number
  default     = 50
  description = "Monthly budget ceiling in USD. Alert thresholds are percentages of this."
}
