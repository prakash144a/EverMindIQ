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
