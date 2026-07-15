variable "project_id" {
  description = "The GCP project ID to deploy resources to."
  type        = string
}

variable "region" {
  description = "The GCP region to deploy resources in."
  type        = string
  default     = "us-central1"
}

variable "dataset_id" {
  description = "The ID of the BigQuery dataset."
  type        = string
  default     = "document_processing"
}

variable "table_id" {
  description = "The ID of the BigQuery table."
  type        = string
  default     = "processed_metadata"
}

variable "image_tag" {
  description = "The tag of the Cloud Run Docker image in Artifact Registry. Set during the second deploy stage."
  type        = string
  default     = "latest"
}
