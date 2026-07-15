#!/usr/bin/env bash
# deploy.sh - Bash deployment script for the serverless document processing pipeline
set -eo pipefail

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

echo -e "${CYAN}=========================================================${NC}"
echo -e "${CYAN}  Starting Document Processing Pipeline Deployment${NC}"
echo -e "${CYAN}=========================================================${NC}"

# 1. Check Prerequisites
echo -e "${YELLOW}[+] Checking prerequisites...${NC}"
for cmd in terraform gcloud; do
    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${RED}Error: '$cmd' is not installed or not in your PATH. Please install it and try again.${NC}"
        exit 1
    fi
done
echo -e "${GREEN}    Prerequisites met (terraform and gcloud are installed).${NC}"

# 2. Check for terraform.tfvars
tfvars_path="terraform/terraform.tfvars"
if [ ! -f "$tfvars_path" ]; then
    echo ""
    echo -e "${RED}Error: '$tfvars_path' not found!${NC}"
    echo -e "${YELLOW}Please create '$tfvars_path' from 'terraform/terraform.tfvars.example' and fill in your GCP details.${NC}"
    exit 1
fi

# 3. Parse variables from terraform.tfvars
echo -e "${YELLOW}[+] Parsing configuration from terraform.tfvars...${NC}"

get_tf_var() {
    local var_name=$1
    # Extracts the value inside double quotes for the given variable name
    grep -E "^[[:space:]]*${var_name}[[:space:]]*=[[:space:]]*\"[^\"]+\"" "$tfvars_path" | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/' || true
}

project_id=$(get_tf_var "project_id")
region=$(get_tf_var "region")
bucket_name="document-processing-ingest-$project_id"

if [ -z "$project_id" ] || [ -z "$region" ]; then
    echo -e "${RED}Error: Failed to parse project_id or region from terraform.tfvars. Make sure they are set and double-quoted.${NC}"
    exit 1
fi

echo -e "${GREEN}    GCP Project: $project_id${NC}"
echo -e "${GREEN}    GCP Region:  $region${NC}"
echo -e "${GREEN}    GCS Bucket:  $bucket_name${NC}"

# 4. Terraform Init
echo ""
echo -e "${YELLOW}[+] Phase 1: Initializing Terraform and deploying baseline resources...${NC}"
cd terraform
echo -e "${GRAY}    Running 'terraform init'...${NC}"
terraform init

echo -e "${GRAY}    Deploying Artifact Registry, GCS Bucket, and BigQuery Table...${NC}"
terraform apply \
  -target=google_artifact_registry_repository.registry \
  -target=google_storage_bucket.input_bucket \
  -target=google_bigquery_table.metadata_table \
  -auto-approve
cd ..
echo -e "${GREEN}    Baseline resources deployed successfully.${NC}"

# 5. Build and Push Container Image via Cloud Build
registry_host="${region}-docker.pkg.dev"
image_url="${registry_host}/${project_id}/document-processing-pipeline/document-processor:latest"

echo ""
echo -e "${YELLOW}[+] Phase 2: Building and pushing container image to Artifact Registry...${NC}"
echo -e "${GRAY}    Image URL: $image_url${NC}"
echo -e "${GRAY}    Running 'gcloud builds submit'...${NC}"

gcloud builds submit --project="$project_id" --tag="$image_url" ./app

echo -e "${GREEN}    Docker image built and pushed successfully.${NC}"

# 6. Apply remaining Terraform resources (Cloud Run, Pub/Sub trigger)
echo ""
echo -e "${YELLOW}[+] Phase 3: Deploying Cloud Run service and Pub/Sub push trigger...${NC}"
cd terraform
echo -e "${GRAY}    Deploying Cloud Run service and subscription...${NC}"
terraform apply -var="image_tag=latest" -auto-approve
cd ..

echo ""
echo -e "${CYAN}=========================================================${NC}"
echo -e "${GREEN}  Deployment Completed Successfully!${NC}"
echo -e "${CYAN}=========================================================${NC}"
echo -e "${CYAN}  Ingestion Bucket: gs://$bucket_name${NC}"
echo -e "${CYAN}  To test, upload a file using:${NC}"
echo -e "${GRAY}    gcloud storage cp test_file.txt gs://$bucket_name/${NC}"
echo -e "${CYAN}=========================================================${NC}"
