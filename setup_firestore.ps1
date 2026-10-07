<#
.SYNOPSIS
  One-time setup of the Firestore database dcr/main.py uses to persist
  {order_id -> client_id, client_secret} mappings (see dcr/utils.py's
  find_client_by_order_id/save_client_mapping).

.DESCRIPTION
  Adapted from the reference repo's own setup_firestore.sh
  (https://github.com/ljogeiger/GE-A2A-Marketplace-Agent). Idempotent --
  `gcloud firestore databases create` on an already-existing default
  database fails harmlessly with ALREADY_EXISTS, which this script
  treats as success, not an error.

.PARAMETER Project
  GCP project ID. If omitted, prompted for.

.PARAMETER Region
  Firestore location (NOT necessarily the same as the Cloud Run region --
  Firestore locations use their own naming, e.g. "nam5", "us-central1").
  Default: nam5.
#>
param(
    [string]$Project,
    [string]$Region = "nam5"
)

$ErrorActionPreference = "Continue"

if (-not $Project) {
    $Project = Read-Host "Enter GOOGLE_CLOUD_PROJECT"
}

Write-Host "Ensuring a Firestore (Native mode) database exists in project '$Project', location '$Region'..." -ForegroundColor Cyan
& gcloud firestore databases create --project=$Project --location=$Region --type=firestore-native 2>&1 | ForEach-Object {
    Write-Host $_
}
Write-Host "`nDone. If the above shows ALREADY_EXISTS, that's fine -- the database was already set up." -ForegroundColor Green
Write-Host "The 'marketplace_clients' collection (see dcr/utils.py) is created lazily on first write -- nothing further to do here." -ForegroundColor DarkGray
