terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.30.0, < 7.0.0"
    }
  }

  # Remote state: SEPARATE GCS bucket/prefix from staging (aion-infra §10 —
  # production and staging state separated). Never committed.
  backend "gcs" {
    # bucket supplied at init: `terraform init -backend-config=backend.hcl`
    prefix = "production"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
