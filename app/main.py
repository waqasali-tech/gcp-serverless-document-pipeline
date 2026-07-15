import base64
import json
import logging
import os
import random
import time
from datetime import datetime, timezone
from typing import List, Optional

from fastapi import FastAPI, HTTPException, Request, status
from google.cloud import bigquery, storage
from pydantic import BaseModel

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("document-processor")

app = FastAPI(title="Serverless Document Processor")

# Configuration from environment variables
PROJECT_ID = os.getenv("GOOGLE_CLOUD_PROJECT")  # Set automatically in Cloud Run or via env
BQ_DATASET = os.getenv("BQ_DATASET", "document_processing")
BQ_TABLE = os.getenv("BQ_TABLE", "metadata")
OCR_DELAY_SECONDS = float(os.getenv("OCR_DELAY_SECONDS", "2.0"))

# Mock classes for local testing without GCP credentials
class MockBlob:
    def download_as_bytes(self):
        logger.info("[MOCK GCS] Downloading file contents")
        return b"Hello world! This is a mock file content containing exactly ten words."

class MockBucket:
    def blob(self, name):
        return MockBlob()

class MockStorageClient:
    def bucket(self, name):
        return MockBucket()

class MockBigQueryClient:
    @property
    def project(self):
        return "mock-project"
    
    def insert_rows_json(self, table_ref, rows):
        logger.info(f"[MOCK BQ] Successfully inserted rows into {table_ref}: {rows}")
        return []

# Initialize GCP clients lazily
storage_client = None
bigquery_client = None

def get_storage_client():
    global storage_client
    if storage_client is None:
        if os.getenv("MOCK_GCP") == "true":
            logger.info("Using Mock Cloud Storage client")
            storage_client = MockStorageClient()
        else:
            storage_client = storage.Client()
    return storage_client

def get_bigquery_client():
    global bigquery_client
    if bigquery_client is None:
        if os.getenv("MOCK_GCP") == "true":
            logger.info("Using Mock BigQuery client")
            bigquery_client = MockBigQueryClient()
        else:
            bigquery_client = bigquery.Client()
    return bigquery_client


# Pub/Sub Payload Pydantic Models
class PubSubMessage(BaseModel):
    data: str
    messageId: str
    publishTime: str
    attributes: Optional[dict] = None

class PubSubEnvelope(BaseModel):
    message: PubSubMessage
    subscription: str


@app.get("/health", status_code=status.HTTP_200_OK)
def health_check():
    """Simple health check endpoint."""
    return {"status": "healthy", "timestamp": datetime.now(timezone.utc).isoformat()}


@app.post("/", status_code=status.HTTP_200_OK)
async def process_document_event(envelope: PubSubEnvelope):
    """
    Receives Pub/Sub push messages triggered by GCS uploads.
    Parses the message, runs simulated OCR, and writes metadata to BigQuery.
    """
    logger.info(f"Received Pub/Sub message ID: {envelope.message.messageId}")
    
    # 1. Decode GCS event from Pub/Sub data
    try:
        decoded_data = base64.b64decode(envelope.message.data).decode("utf-8")
        gcs_event = json.loads(decoded_data)
    except Exception as e:
        logger.error(f"Failed to decode Pub/Sub message data: {e}")
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid base64 payload or non-JSON content in message.data"
        )
    
    # Extract object details from GCS notification
    # Note: Event can be OBJECT_FINALIZE or OBJECT_DELETE. We only process uploads (OBJECT_FINALIZE).
    # In GCS notifications, OBJECT_DELETE has size=0 or missing. We check for finalize attributes.
    filename = gcs_event.get("name")
    bucket_name = gcs_event.get("bucket")
    content_type = gcs_event.get("contentType", "application/octet-stream")
    size_str = gcs_event.get("size", "0")
    file_size = int(size_str)
    
    # Ignore folder creation events or deleted objects
    if not filename or filename.endswith("/"):
        logger.info(f"Skipping directory creation or empty filename: {filename}")
        return {"status": "ignored", "reason": "directory_or_empty_name"}
    
    logger.info(f"Processing file: gs://{bucket_name}/{filename} (MIME: {content_type}, Size: {file_size} bytes)")
    
    # 2. Simulated OCR and metadata extraction
    word_count = 0
    language = "unknown"
    tags = []
    
    try:
        # Check if the file actually exists and read properties/content if txt
        s_client = get_storage_client()
        bucket = s_client.bucket(bucket_name)
        blob = bucket.blob(filename)
        
        if content_type.startswith("text/") or filename.endswith(".txt"):
            # Real word count for text files
            logger.info(f"Downloading text file content to count words: {filename}")
            content_bytes = blob.download_as_bytes()
            content_text = content_bytes.decode("utf-8", errors="ignore")
            word_count = len(content_text.split())
            language = "en"  # Default assumption for text files
            tags = ["text", "plain-text", "parsed"]
        else:
            # Simulated OCR delay for other files (PDF, images, etc.)
            logger.info(f"Simulating OCR processing for {filename} with a {OCR_DELAY_SECONDS}s delay...")
            if OCR_DELAY_SECONDS > 0:
                time.sleep(OCR_DELAY_SECONDS)
            
            # Generate simulated metadata
            word_count = random.randint(50, 1500)
            language = random.choice(["en", "es", "fr", "de"])
            
            # Generate relevant tags based on file type
            if "pdf" in content_type.lower() or filename.endswith(".pdf"):
                tags = ["pdf", "document", "simulated-ocr"]
            elif "image" in content_type.lower() or filename.split(".")[-1].lower() in ["png", "jpg", "jpeg", "tiff"]:
                tags = ["image", "scan", "simulated-ocr"]
            else:
                tags = ["binary", "unsupported-ocr-type"]
                
    except Exception as e:
        logger.error(f"Error accessing Cloud Storage: {e}")
        # We raise a 500 error so Pub/Sub will retry the delivery
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to access file in Cloud Storage: {str(e)}"
        )
    
    # 3. Stream Metadata to BigQuery
    processed_at = datetime.now(timezone.utc).isoformat()
    metadata_row = {
        "filename": filename,
        "processed_at": processed_at,
        "word_count": word_count,
        "language": language,
        "tags": tags,
        "file_size": file_size,
        "content_type": content_type
    }
    
    try:
        bq_client = get_bigquery_client()
        # Formulate full table ID
        # If PROJECT_ID is set, use it. Otherwise, bigquery client infers project from environment credentials.
        if PROJECT_ID:
            table_ref = f"{PROJECT_ID}.{BQ_DATASET}.{BQ_TABLE}"
        else:
            table_ref = f"{bq_client.project}.{BQ_DATASET}.{BQ_TABLE}"
            
        logger.info(f"Streaming metadata to BigQuery table: {table_ref}")
        errors = bq_client.insert_rows_json(table_ref, [metadata_row])
        
        if errors:
            logger.error(f"Failed to insert rows into BigQuery: {errors}")
            raise Exception(f"BigQuery insert errors: {errors}")
            
        logger.info(f"Successfully processed and streamed metadata for {filename}")
        
    except Exception as e:
        logger.error(f"Error writing to BigQuery: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to stream metadata to BigQuery: {str(e)}"
        )
        
    return {
        "status": "success",
        "processed_file": f"gs://{bucket_name}/{filename}",
        "metadata": metadata_row
    }

if __name__ == "__main__":
    import uvicorn
    # Cloud Run injects PORT environment variable, defaults to 8080
    port = int(os.getenv("PORT", 8080))
    uvicorn.run("main:app", host="0.0.0.0", port=port)
