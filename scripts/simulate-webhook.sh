#!/usr/bin/env bash
# Sends the same signed payload GitHub Actions sends, so the whole trigger chain can be
# exercised locally without exposing the cluster to the internet.
#
#   ./simulate-webhook.sh <listener-url> <service> <env> <image-tag> [git-url]
#
# Run it once with a wrong secret too: the listener must refuse it.
set -euo pipefail

URL="${1:?listener URL, e.g. https://github-listener-istat-ndc-cicd.apps-crc.testing}"
SERVICE="${2:?service name}"
ENVIRONMENT="${3:?dev or test}"
TAG="${4:?image tag}"
GIT_URL="${5:-https://github.com/ndc-dxc/istat-ndc-$SERVICE}"
SECRET="${WEBHOOK_SECRET:?set WEBHOOK_SECRET to the value stored in the github-webhook-secret Secret}"

BODY=$(cat <<JSON
{"action":"deploy","client_payload":{"service":"$SERVICE","env":"$ENVIRONMENT","imageTag":"$TAG","gitUrl":"$GIT_URL","gitRevision":"main"}}
JSON
)

SIG="sha256=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')"

curl -sk -X POST "$URL" \
  -H 'Content-Type: application/json' \
  -H 'X-GitHub-Event: repository_dispatch' \
  -H "X-Hub-Signature-256: $SIG" \
  -d "$BODY" -w '\nHTTP %{http_code}\n'
