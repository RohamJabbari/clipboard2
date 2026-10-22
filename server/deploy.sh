#!/usr/bin/env bash
# Deploys clipboard2-api to Cloud Run (rohams-tools). The DB lives on the shared pjlogistik instance,
# so instances and the pool stay small: at most 3 × 4 connections. The API authenticates its own
# callers; --no-invoker-iam-check because the org's domain-restricted sharing forbids allUsers.
set -euo pipefail
cd "$(dirname "$0")"
gcloud run deploy clipboard2-api \
  --project=rohams-tools \
  --region=europe-west1 \
  --source=. \
  --service-account=clipboard2@rohams-tools.iam.gserviceaccount.com \
  --no-invoker-iam-check \
  --min-instances=0 \
  --max-instances=3 \
  --concurrency=40 \
  --cpu=1 \
  --memory=512Mi \
  --set-env-vars=INSTANCE_CONNECTION_NAME=pjlogistik-platform:europe-west1:pjlogistik-datasource,DB_USER=clipboard2@rohams-tools.iam,DB_NAME=clipboard2-db,DB_POOL_MAX=4,BUCKET=clipboard2
