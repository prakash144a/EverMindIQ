output "api_url" {
  value       = google_cloud_run_v2_service.api.uri
  description = "Base URL of the deployed backend."
}

output "audio_bucket" {
  value = google_storage_bucket.audio.name
}

output "ingest_topic" {
  value = google_pubsub_topic.ingest.id
}

output "backend_service_account" {
  value = google_service_account.backend.email
}
