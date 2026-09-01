terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0, < 6.0.0"
    }
  }

  # Remote state (S3 + native lockfile or DynamoDB) is configured at init time,
  # separated per environment — mirrors the GCP profile. Left partial here so a
  # bare `validate` needs no backend.
  backend "s3" {}
}

provider "aws" {
  region = var.region
}
