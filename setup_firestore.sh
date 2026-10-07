#!/usr/bin/env bash
# Bash equivalent of setup_firestore.ps1 -- see that file's own header
# comment for the full rationale.
#
# Usage: ./setup_firestore.sh --project my-project [--region nam5]
set -uo pipefail

PROJECT=""
REGION="nam5"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PROJECT" ]]; then
  read -r -p "Enter GOOGLE_CLOUD_PROJECT: " PROJECT
fi

echo "Ensuring a Firestore (Native mode) database exists in project '${PROJECT}', location '${REGION}'..."
gcloud firestore databases create --project="$PROJECT" --location="$REGION" --type=firestore-native

echo
echo "Done. If the above shows ALREADY_EXISTS, that's fine -- the database was already set up."
echo "The 'marketplace_clients' collection (see dcr/utils.py) is created lazily on first write -- nothing further to do here."
