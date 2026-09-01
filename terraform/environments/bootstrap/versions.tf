terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.30.0, < 7.0.0"
    }
  }

  # LOCAL backend — this is the one stack that cannot use remote state because
  # it CREATES the remote-state buckets (aion-infra §10). Its state file
  # (terraform.tfstate) is git-ignored. Optionally migrate it into a bucket
  # after the first apply; documented in docs/deployment.md.
}

provider "google" {
  project = var.project_id
  region  = var.region
}
