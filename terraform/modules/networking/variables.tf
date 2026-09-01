variable "project_id" {
  type        = string
  description = "GCP project ID that owns this environment's network."
}

variable "environment" {
  type        = string
  description = "Environment name (staging | production)."
}

variable "region" {
  type        = string
  description = "GCP region for the regional subnet."
}

variable "name_prefix" {
  type        = string
  description = "Prefix applied to all resource names, e.g. aion-staging."
}

variable "runtime_subnet_cidr" {
  type        = string
  description = "CIDR for the Cloud Run Direct VPC egress subnet."
  default     = "10.8.0.0/28"
}
