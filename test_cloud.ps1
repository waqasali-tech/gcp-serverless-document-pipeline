# test_cloud.ps1 - Automates testing the deployed event-driven pipeline in the cloud
$ErrorActionPreference = "Stop"

$tfvarsPath = "terraform/terraform.tfvars"
if (-not (Test-Path $tfvarsPath)) {
    Write-Host "Error: '$tfvarsPath' not found. Please create it and deploy first." -ForegroundColor Red
    Exit 1
}

$tfvarsContent = Get-Content $tfvarsPath

function Get-TfVar($name) {
    if ($tfvarsContent -match "$name\s*=\s*`"(.*?)`"") {
        return $Matches[1]
    }
    return $null
}

$projectId = Get-TfVar "project_id"
$bucketName = "document-processing-ingest-$projectId"
$datasetId = Get-TfVar "dataset_id"
$tableId = Get-TfVar "table_id"

if (-not $datasetId) { $datasetId = "document_processing" }
if (-not $tableId) { $tableId = "processed_metadata" }

if (-not $projectId) {
    Write-Host "Error: Failed to parse project_id from terraform/terraform.tfvars." -ForegroundColor Red
    Exit 1
}

Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  Testing Cloud Pipeline: Event-Driven Processing" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "Project: $projectId" -ForegroundColor Green
Write-Host "Bucket:  gs://$bucketName" -ForegroundColor Green
Write-Host "Table:   $projectId.$datasetId.$tableId" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Cyan

# 1. Create a local temp file
$timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$tempFile = "test_cloud_upload_$timestamp.txt"
"Hello Google Cloud Serverless Pipeline! This text has eight words." | Out-File -FilePath $tempFile -Encoding ascii
Write-Host "[+] Created temporary local file: $tempFile" -ForegroundColor Yellow

# 2. Upload to GCS
Write-Host "[+] Uploading $tempFile to gs://$bucketName/..." -ForegroundColor Yellow
gcloud storage cp $tempFile "gs://$bucketName/$tempFile"

# 3. Wait for propagation
Write-Host "[+] Waiting 8 seconds for GCS, Pub/Sub, Cloud Run, and BigQuery to process..." -ForegroundColor Yellow
Start-Sleep -Seconds 8

# 4. Check BigQuery
Write-Host "[+] Querying BigQuery for the metadata record..." -ForegroundColor Yellow
$query = "SELECT filename, processed_at, word_count, language, tags, file_size FROM \`$projectId.$datasetId.$tableId\` WHERE filename = '$tempFile'"
bq query --project_id=$projectId --use_legacy_sql=false $query

# 5. Cleanup
Write-Host "[+] Cleaning up local file: $tempFile" -ForegroundColor Yellow
Remove-Item $tempFile

Write-Host "[+] Cloud pipeline test sequence finished!" -ForegroundColor Green
