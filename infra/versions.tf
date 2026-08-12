terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  # Some APIs (e.g. billingbudgets) require a user quota project when
  # authenticating with user ADC; route it through this project.
  user_project_override = true
  billing_project       = var.project_id
}
