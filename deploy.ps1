# deploy.ps1 - Windows PowerShell deployment script for the serverless document processing pipeline
$ErrorActionPreference = "Stop"

Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  Starting Document Processing Pipeline Deployment" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

# 1. Check Prerequisites
Write-Host "[+] Checking prerequisites..." -ForegroundColor Yellow
$commands = @("terraform", "gcloud")
foreach ($cmd in $commands) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Error "Error: '$cmd' is not installed or not in your PATH. Please install it and try again."
    }
}
Write-Host "    Prerequisites met (terraform and gcloud are installed)." -ForegroundColor Green

# 2. Check for terraform.tfvars
$tfvarsPath = "terraform/terraform.tfvars"
if (-not (Test-Path $tfvarsPath)) {
    Write-Host ""
    Write-Host "Error: '$tfvarsPath' not found!" -ForegroundColor Red
    Write-Host "Please create '$tfvarsPath' from 'terraform/terraform.tfvars.example' and fill in your GCP details." -ForegroundColor Yellow
    Exit 1
}

# 3. Parse variables from terraform.tfvars
Write-Host "[+] Parsing configuration from terraform.tfvars..." -ForegroundColor Yellow

# Read the file as a single raw string instead of a line array
$tfvarsContent = Get-Content $tfvarsPath -Raw

function Get-TfVar($name) {
    # Using [regex]::Match explicitly to guarantee it captures cleanly on Windows PowerShell
    $pattern = "$name\s*=\s*`"(.*?)`""
    $match = [regex]::Match($tfvarsContent, $pattern)
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return $null
}

$projectId = Get-TfVar "project_id"
$region = Get-TfVar "region"
$bucketName = "document-processing-ingest-$projectId"

if (-not $projectId -or -not $region) {
    Write-Error "Error: Failed to parse project_id or region from terraform.tfvars. Make sure they are set and double-quoted."
}

Write-Host "    GCP Project: $projectId" -ForegroundColor Green
Write-Host "    GCP Region:  $region" -ForegroundColor Green
Write-Host "    GCS Bucket:  $bucketName" -ForegroundColor Green

# 4. Terraform Init
Write-Host ""
Write-Host "[+] Phase 1: Initializing Terraform and deploying baseline resources..." -ForegroundColor Yellow
Push-Location terraform
try {
    Write-Host "    Running 'terraform init'..." -ForegroundColor Gray
    terraform init

    # We target the Artifact Registry, Storage Bucket, and BQ Table (dataset is auto-created as a dependency)
    Write-Host "    Deploying Artifact Registry, GCS Bucket, and BigQuery Table..." -ForegroundColor Gray
    terraform apply `
      -target=google_artifact_registry_repository.registry `
      -target=google_storage_bucket.input_bucket `
      -target=google_bigquery_table.metadata_table `
      -auto-approve
}
finally {
    Pop-Location
}
Write-Host "    Baseline resources deployed successfully." -ForegroundColor Green

# 5. Build and Push Container Image via Cloud Build
$registryHost = "${region}-docker.pkg.dev"
$imageUrl = "${registryHost}/${projectId}/document-processing-pipeline/document-processor:latest"

Write-Host ""
Write-Host "[+] Phase 2: Building and pushing container image to Artifact Registry..." -ForegroundColor Yellow
Write-Host "    Image URL: $imageUrl" -ForegroundColor Gray
Write-Host "    Running 'gcloud builds submit'..." -ForegroundColor Gray

gcloud builds submit --project=$projectId --tag=$imageUrl ./app

Write-Host "    Docker image built and pushed successfully." -ForegroundColor Green

# 6. Apply remaining Terraform resources (Cloud Run, Pub/Sub trigger)
Write-Host ""
Write-Host "[+] Phase 3: Deploying Cloud Run service and Pub/Sub push trigger..." -ForegroundColor Yellow
Push-Location terraform
try {
    Write-Host "    Deploying Cloud Run service and subscription..." -ForegroundColor Gray
    terraform apply -var="image_tag=latest" -auto-approve
}
finally {
    Pop-Location
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  Deployment Completed Successfully!" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  Ingestion Bucket: gs://$bucketName" -ForegroundColor Cyan
Write-Host "  To test, upload a file using:" -ForegroundColor Cyan
Write-Host "    gcloud storage cp test_file.txt gs://$bucketName/" -ForegroundColor Gray
Write-Host "=========================================================" -ForegroundColor Green