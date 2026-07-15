import base64
import json
import os
import subprocess
import sys
import time
import requests

def run_tests():
    # Start FastAPI server in MOCK mode
    env = os.environ.copy()
    env["MOCK_GCP"] = "true"
    env["PORT"] = "8099"
    env["OCR_DELAY_SECONDS"] = "2.0"

    print("=========================================================")
    print("  Starting Local FastAPI Server in MOCK mode on port 8099")
    print("=========================================================")
    
    # Run the server as a background process
    process = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "main:app", "--host", "127.0.0.1", "--port", "8099"],
        cwd="app",
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )

    # Wait for the server to start up
    time.sleep(2.5)

    # Check if the process started successfully
    if process.poll() is not None:
        stdout, stderr = process.communicate()
        print("[-] Failed to start FastAPI server:")
        print(f"STDOUT: {stdout}")
        print(f"STDERR: {stderr}")
        sys.exit(1)

    try:
        # Test 1: Health Check Endpoint
        print("\n[+] Test 1: Checking Health endpoint...")
        resp = requests.get("http://127.0.0.1:8099/health")
        print(f"    Status Code: {resp.status_code}")
        print(f"    Response JSON: {resp.json()}")
        assert resp.status_code == 200, f"Expected 200, got {resp.status_code}"
        print("    --> Test 1 Passed!")

        # Test 2: Text file upload (performs download and word count)
        print("\n[+] Test 2: Uploading plain text file (gs://test-bucket/doc.txt)...")
        gcs_event_txt = {
            "name": "doc.txt",
            "bucket": "test-bucket",
            "contentType": "text/plain",
            "size": "67"
        }
        encoded_data_txt = base64.b64encode(json.dumps(gcs_event_txt).encode("utf-8")).decode("utf-8")
        
        envelope_txt = {
            "message": {
                "data": encoded_data_txt,
                "messageId": "msg-12345",
                "publishTime": "2026-06-22T12:00:00Z"
            },
            "subscription": "projects/mock-project/subscriptions/mock-sub"
        }

        resp = requests.post("http://127.0.0.1:8099/", json=envelope_txt)
        print(f"    Status Code: {resp.status_code}")
        print(f"    Response JSON: {json.dumps(resp.json(), indent=2)}")
        assert resp.status_code == 200, f"Expected 200, got {resp.status_code}"
        
        body = resp.json()
        assert body["status"] == "success"
        # Mock content has exactly 12 words
        assert body["metadata"]["word_count"] == 12, f"Expected 12 words, got {body['metadata']['word_count']}"
        assert body["metadata"]["language"] == "en"
        assert "text" in body["metadata"]["tags"]
        print("    --> Test 2 Passed!")

        # Test 3: PDF file upload (triggers simulated OCR delay)
        print("\n[+] Test 3: Uploading PDF document (gs://test-bucket/invoice.pdf)...")
        gcs_event_pdf = {
            "name": "invoice.pdf",
            "bucket": "test-bucket",
            "contentType": "application/pdf",
            "size": "1048576"
        }
        encoded_data_pdf = base64.b64encode(json.dumps(gcs_event_pdf).encode("utf-8")).decode("utf-8")
        
        envelope_pdf = {
            "message": {
                "data": encoded_data_pdf,
                "messageId": "msg-67890",
                "publishTime": "2026-06-22T12:05:00Z"
            },
            "subscription": "projects/mock-project/subscriptions/mock-sub"
        }

        start_time = time.time()
        resp = requests.post("http://127.0.0.1:8099/", json=envelope_pdf)
        elapsed = time.time() - start_time
        
        print(f"    Status Code: {resp.status_code}")
        print(f"    Response JSON: {json.dumps(resp.json(), indent=2)}")
        print(f"    Request Duration: {elapsed:.2f} seconds")
        assert resp.status_code == 200, f"Expected 200, got {resp.status_code}"
        
        body = resp.json()
        assert body["status"] == "success"
        assert body["metadata"]["content_type"] == "application/pdf"
        assert "pdf" in body["metadata"]["tags"]
        assert elapsed >= 2.0, f"Expected simulated delay of >= 2 seconds, but request finished in {elapsed:.2f}s"
        print("    --> Test 3 Passed!")

        print("\n=========================================================")
        print("  All local integration tests passed successfully!")
        print("=========================================================")

    except AssertionError as e:
        print(f"\n[-] Assert failed: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"\n[-] Error running tests: {e}")
        sys.exit(1)
    finally:
        print("[+] Terminating FastAPI local server...")
        process.terminate()
        process.wait()

if __name__ == "__main__":
    run_tests()
