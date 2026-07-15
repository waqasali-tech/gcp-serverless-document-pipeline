#!/usr/bin/env bash
# test_cloud.sh - Automates testing the deployed event-driven pipeline in the cloud
set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

tfvars_path="terraform/terraform.tfvars"
if [ ! -f "$tfvars_path" ]; then
    echo -e "${RED}Error: '$tfvars_path' not found. Please create it and deploy first.${NC}"
    exit 1
fi

get_tf_var() {
    local var_name=$1
    grep -E "^[[:space:]]*${var_name}[[:space:]]*=[[:space:]]*\"[^\"]+\"" "$tfvars_path" | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/' || true
}

project_id=$(get_tf_var "project_id")
bucket_name="document-processing-ingest-$project_id"
dataset_id=$(get_tf_var "dataset_id")
table_id=$(get_tf_var "table_id")

if [ -z "$dataset_id" ]; then dataset_id="document_processing"; fi
if [ -z "$table_id" ]; then table_id="processed_metadata"; fi

if [ -z "$project_id" ]; then
    echo -e "${RED}Error: Failed to parse project_id from terraform/terraform.tfvars.${NC}"
    exit 1
fi

echo -e "${CYAN}=========================================================${NC}"
echo -e "${CYAN}  Testing Cloud Pipeline: Event-Driven Processing${NC}"
echo -e "${CYAN}=========================================================${NC}"
echo -e "Project: ${GREEN}$project_id${NC}"
echo -e "Bucket:  ${GREEN}gs://$bucket_name${NC}"
echo -e "Table:   ${GREEN}$project_id.$dataset_id.$table_id${NC}"
echo -e "${CYAN}=========================================================${NC}"

# 1. Create a local temp file
temp_file="test_cloud_upload_$(date +%s).txt"
echo "Hello Google Cloud Serverless Pipeline! This text has eight words." > "$temp_file"
echo -e "${YELLOW}[+] Created temporary local file: $temp_file${NC}"

# 2. Upload to GCS
echo -e "${YELLOW}[+] Uploading $temp_file to gs://$bucket_name/...${NC}"
gcloud storage cp "$temp_file" "gs://$bucket_name/$temp_file"

# 3. Wait for propagation
echo -e "${YELLOW}[+] Waiting 8 seconds for GCS, Pub/Sub, Cloud Run, and BigQuery to process...${NC}"
sleep 8

# 4. Check BigQuery
echo -e "${YELLOW}[+] Querying BigQuery for the metadata record...${NC}"
query="SELECT filename, processed_at, word_count, language, tags, file_size FROM \`$project_id.$dataset_id.$table_id\` WHERE filename = '$temp_file'"
bq query --project_id="$project_id" --use_legacy_sql=false "$query"

# 5. Cleanup
echo -e "${YELLOW}[+] Cleaning up local file: $temp_file${NC}"
rm "$temp_file"

echo -e "${GREEN}[+] Cloud pipeline test sequence finished!${NC}"
