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

variable "monthly_budget_usd" {
  type        = number
  default     = 50
  description = "Monthly budget ceiling in USD. Alert thresholds are percentages of this."
}
