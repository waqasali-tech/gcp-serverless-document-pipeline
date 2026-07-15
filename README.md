# Serverless Event-Driven Document Processing Pipeline on GCP

This repository contains a serverless event-driven document processing pipeline built on Google Cloud Platform. 

## Architecture Overview

1. **Ingestion**: Users upload files (PDFs, images, text, etc.) to a **Cloud Storage** bucket.
2. **Trigger**: GCS triggers a Pub/Sub message via **Cloud Storage Pub/Sub Notifications** (`OBJECT_FINALIZE` event).
3. **Processor**: A **FastAPI** Python application hosted on **Cloud Run** receives the Pub/Sub message securely via an **Authenticated Push Subscription** (OIDC token authentication).
4. **Processing**: The application reads the file metadata from GCS. If it is a `.txt` file, it downloads the content to compute the actual word count. If it is another type, it simulates an OCR delay (e.g. 2 seconds) and generates simulated tags, language, and word count.
5. **Storage**: The application streams the extracted metadata (filename, processing timestamp, word count, language, tags, size, content type) into a **BigQuery** dataset.

---

## Directory Structure

```
├── app/
│   ├── main.py              # FastAPI Python application logic
│   ├── requirements.txt     # Python dependencies
│   └── Dockerfile           # Docker image definition for Cloud Run
├── terraform/
│   ├── providers.tf         # Terraform provider definitions
│   ├── variables.tf         # Input variables
│   ├── main.tf              # GCP Infrastructure configuration
│   └── terraform.tfvars.example # Template config file
├── deploy.ps1               # Windows PowerShell deployment orchestrator
├── deploy.sh                # Linux/macOS Bash deployment orchestrator
└── README.md                # Project documentation
```

---

## Prerequisites

Before running the deployment, ensure you have the following installed and configured on your machine:

1. **Google Cloud SDK (gcloud)**: Installed and authenticated.
   - Authenticate with your Google account:
     ```bash
     gcloud auth login
     ```
   - Authenticate Application Default Credentials (ADC) for Terraform:
     ```bash
     gcloud auth application-default login
     ```
2. **Terraform**: Installed and added to your `PATH` (v1.3.0 or higher).
3. **GCP Project**: A Google Cloud Project with billing enabled.

---

## Deployment Steps

1. **Configure Variables**:
   Navigate to the `terraform/` directory, copy the example variables file, and open it to fill in your GCP project details:
   ```bash
   cp terraform/terraform.tfvars.example terraform/terraform.tfvars
   ```
   Modify `terraform/terraform.tfvars`:
   ```hcl
   project_id  = "your-gcp-project-id"
   region      = "us-central1"
   bucket_name = "your-globally-unique-bucket-name"
   ```

2. **Execute Deploy Script**:
   Run the helper deployment script. It handles the deployment cycle automatically (setting up Artifact Registry, building/pushing the container using Cloud Build, and deploying Cloud Run and Pub/Sub triggers).

   - **On Windows (PowerShell)**:
     ```powershell
     Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
     .\deploy.ps1
     ```
   - **On Linux/macOS (Bash)**:
     ```bash
     chmod +x deploy.sh
     ./deploy.sh
     ```

---

## Verification and Testing

### 1. Upload a Test File
You can upload files via the Google Cloud Console, or use the `gcloud` CLI:

- **Create a sample text file**:
  ```bash
  echo "Hello Google Cloud Serverless Pipeline! This text has eight words." > test_file.txt
  ```

- **Upload to the bucket**:
  ```bash
  gcloud storage cp test_file.txt gs://your-globally-unique-bucket-name/
  ```

### 2. View Cloud Run Logs
To verify that the function has triggered, tail the Cloud Run logs:
```bash
gcloud beta run services logs tail document-processor --project=your-gcp-project-id --region=us-central1
```
You should see output similar to:
```
INFO:document-processor:Received Pub/Sub message ID: 1234567890
INFO:document-processor:Processing file: gs://your-globally-unique-bucket-name/test_file.txt
INFO:document-processor:Downloading text file content to count words: test_file.txt
INFO:document-processor:Streaming metadata to BigQuery table: your-project.document_processing.metadata
INFO:document-processor:Successfully processed and streamed metadata for test_file.txt
```

### 3. Query BigQuery Metadata
Verify that the metadata was successfully streamed to the table:
```bash
bq query --use_legacy_sql=false \
  'SELECT filename, processed_at, word_count, language, tags, file_size FROM `your-gcp-project-id.document_processing.metadata` ORDER BY processed_at DESC'
```
Example Output:
| filename | processed_at | word_count | language | tags | file_size |
|---|---|---|---|---|---|
| `test_file.txt` | `2026-06-23 00:00:00 UTC` | `8` | `en` | `["text", "plain-text", "parsed"]` | `67` |

---

## Cleanup

To clean up and destroy all provisioned GCP resources to avoid incurring ongoing charges:
```bash
cd terraform
terraform destroy
```
