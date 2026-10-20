"""Create the Boundary session-recording bucket in MinIO.
Replaces the mc client (whose image was removed from Docker Hub) with a small
boto3 call against MinIO's S3 API. Boundary accesses the bucket with MinIO's root
credentials directly, since credential rotation is disabled on the storage bucket.
"""
import os
import sys
import time

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError, EndpointConnectionError

endpoint = os.environ.get("MINIO_ENDPOINT", "http://minio:9000")
access_key = os.environ["MINIO_ACCESS_KEY"]
secret_key = os.environ["MINIO_SECRET_KEY"]
bucket = os.environ.get("MINIO_BUCKET", "boundary-session-recordings")

s3 = boto3.client(
    "s3",
    endpoint_url=endpoint,
    aws_access_key_id=access_key,
    aws_secret_access_key=secret_key,
    region_name="us-east-1",
    config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
)

print("[minio-bootstrap] waiting for MinIO...", flush=True)
for _ in range(40):
    try:
        s3.list_buckets()
        break
    except (EndpointConnectionError, ClientError, Exception) as e:  # noqa: BLE001
        print(f"[minio-bootstrap]   not ready: {e}", flush=True)
        time.sleep(3)
else:
    print("[minio-bootstrap] MinIO never became reachable.", flush=True)
    sys.exit(1)

try:
    s3.create_bucket(Bucket=bucket)
    print(f"[minio-bootstrap] created bucket '{bucket}'.", flush=True)
except ClientError as e:
    code = e.response.get("Error", {}).get("Code", "")
    if code in ("BucketAlreadyOwnedByYou", "BucketAlreadyExists"):
        print(f"[minio-bootstrap] bucket '{bucket}' already exists.", flush=True)
    else:
        raise

print("[minio-bootstrap] done.", flush=True)
