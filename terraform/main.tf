data "google_project" "project" {}

# Enable required Google APIs
resource "google_project_service" "enabled_apis" {
  for_each = toset([
    "artifactregistry.googleapis.com",
    "run.googleapis.com",
    "pubsub.googleapis.com",
    "bigquery.googleapis.com",
    "storage.googleapis.com",
    "cloudbuild.googleapis.com"
  ])
  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}

# 1. Google Artifact Registry Repository
resource "google_artifact_registry_repository" "registry" {
  location      = var.region
  repository_id = "document-processing-pipeline"
  description   = "Docker repository for document processing pipeline"
  format        = "DOCKER"
  depends_on    = [google_project_service.enabled_apis]
}

# 2. Google Cloud Storage Bucket for Ingestion
resource "google_storage_bucket" "input_bucket" {
  name                        = "document-processing-ingest-${var.project_id}"
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true
  depends_on                  = [google_project_service.enabled_apis]
}

# 3. Google Pub/Sub Topic for Storage Events
resource "google_pubsub_topic" "bucket_topic" {
  name       = "document-upload-topic"
  depends_on = [google_project_service.enabled_apis]
}

# 4. GCS Pub/Sub Publisher IAM Policy
# Retrieves the GCS system service account
data "google_storage_project_service_account" "gcs_account" {
  depends_on = [google_project_service.enabled_apis]
}

# Grants GCS service account permission to publish messages to the Pub/Sub topic
resource "google_pubsub_topic_iam_member" "gcs_publisher" {
  topic  = google_pubsub_topic.bucket_topic.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${data.google_storage_project_service_account.gcs_account.email_address}"
}

# 5. GCS Event Notification Config
resource "google_storage_notification" "notification" {
  bucket         = google_storage_bucket.input_bucket.name
  payload_format = "JSON_API_V1"
  topic          = google_pubsub_topic.bucket_topic.id
  event_types    = ["OBJECT_FINALIZE"]
  
  depends_on = [google_pubsub_topic_iam_member.gcs_publisher]
}

# 6. BigQuery Dataset & Table for Metadata Storage
resource "google_bigquery_dataset" "dataset" {
  dataset_id                  = var.dataset_id
  location                    = var.region
  delete_contents_on_destroy  = true
  depends_on                  = [google_project_service.enabled_apis]
}

resource "google_bigquery_table" "metadata_table" {
  dataset_id          = google_bigquery_dataset.dataset.dataset_id
  table_id            = var.table_id
  deletion_protection = false

  schema = <<EOF
[
  {
    "name": "filename",
    "type": "STRING",
    "mode": "REQUIRED",
    "description": "The name of the processed file in Cloud Storage"
  },
  {
    "name": "processed_at",
    "type": "TIMESTAMP",
    "mode": "REQUIRED",
    "description": "Timestamp when processing occurred"
  },
  {
    "name": "word_count",
    "type": "INTEGER",
    "mode": "NULLABLE",
    "description": "Word count extracted via simulated OCR"
  },
  {
    "name": "language",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "Simulated language detected (e.g. en, es, fr, de)"
  },
  {
    "name": "tags",
    "type": "STRING",
    "mode": "REPEATED",
    "description": "Extracted list of tags"
  },
  {
    "name": "file_size",
    "type": "INTEGER",
    "mode": "NULLABLE",
    "description": "Size of the file in bytes"
  },
  {
    "name": "content_type",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "MIME content type of the file"
  }
]
EOF
}

# 7. Cloud Run Dedicated Service Account & Permissions
resource "google_service_account" "cloud_run_sa" {
  account_id   = "document-processor-sa"
  display_name = "Cloud Run Document Processor Service Account"
  depends_on   = [google_project_service.enabled_apis]
}

# Grant Cloud Run SA read permissions to the GCS bucket
resource "google_storage_bucket_iam_member" "storage_viewer" {
  bucket = google_storage_bucket.input_bucket.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

# Grant Cloud Run SA BigQuery User permissions (to run jobs/inserts in the project)
resource "google_project_iam_member" "bigquery_user" {
  project    = var.project_id
  role       = "roles/bigquery.user"
  member     = "serviceAccount:${google_service_account.cloud_run_sa.email}"
  depends_on = [google_project_service.enabled_apis]
}

# Grant Cloud Run SA BigQuery Data Editor permissions on the specific dataset
resource "google_bigquery_dataset_iam_member" "bigquery_editor" {
  dataset_id = google_bigquery_dataset.dataset.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

# 8. Cloud Run Service running the FastAPI app
resource "google_cloud_run_v2_service" "processor" {
  name     = "document-processor"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.cloud_run_sa.email
    
    containers {
      # Image is tagged dynamically based on the build input
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.registry.repository_id}/document-processor:${var.image_tag}"
      
      ports {
        container_port = 8080
      }

      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
      env {
        name  = "BQ_DATASET"
        value = google_bigquery_dataset.dataset.dataset_id
      }
      env {
        name  = "BQ_TABLE"
        value = google_bigquery_table.metadata_table.table_id
      }
      env {
        name  = "OCR_DELAY_SECONDS"
        value = "2.0"
      }
    }
  }

  depends_on = [
    google_artifact_registry_repository.registry
  ]
}

# 9. Pub/Sub Push Subscription Invoker IAM & Token Config
# Dedicated Service Account for Pub/Sub to invoke Cloud Run
resource "google_service_account" "pubsub_invoker" {
  account_id   = "pubsub-invoker-sa"
  display_name = "Pub/Sub Invoker Service Account"
  depends_on   = [google_project_service.enabled_apis]
}

# Grant Pub/Sub SA permission to invoke the Cloud Run Service
resource "google_cloud_run_v2_service_iam_member" "pubsub_invoker_run" {
  name     = google_cloud_run_v2_service.processor.name
  location = google_cloud_run_v2_service.processor.location
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.pubsub_invoker.email}"
}

# IMPORTANT: Grant Pub/Sub system agent Token Creator role on our invoker SA
resource "google_service_account_iam_member" "pubsub_token_creator" {
  service_account_id = google_service_account.pubsub_invoker.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

# 10. Pub/Sub Push Subscription pointing to Cloud Run
resource "google_pubsub_subscription" "push_subscription" {
  name                 = "document-processor-subscription"
  topic                = google_pubsub_topic.bucket_topic.name
  ack_deadline_seconds = 60

  push_config {
    push_endpoint = google_cloud_run_v2_service.processor.uri
    
    oidc_token {
      service_account_email = google_service_account.pubsub_invoker.email
      audience              = google_cloud_run_v2_service.processor.uri
    }
  }

  # Ensure IAM bindings are active before creating the subscription
  depends_on = [
    google_cloud_run_v2_service_iam_member.pubsub_invoker_run,
    google_service_account_iam_member.pubsub_token_creator
  ]
}
