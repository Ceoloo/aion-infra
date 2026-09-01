terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.30.0, < 7.0.0"
    }
  }

  # Remote state: GCS bucket provisioned by environments/bootstrap. State is
  # encrypted at rest, access-controlled, natively locked, and SEPARATE per
  # environment via the prefix (aion-infra §10). Never committed.
  backend "gcs" {
    # bucket is supplied at init: `terraform init -backend-config=backend.hcl`
    prefix = "staging"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
