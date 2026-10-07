#!/usr/bin/env bash
# Bash equivalent of deploy.ps1 -- see that file's own header comment for
# the full rationale (two Cloud Run services, each two-phase-deployed to
# solve the "doesn't know its own URL yet" problem). Kept functionally
# identical to deploy.ps1, not a reduced version.
#
# Usage: ./deploy.sh --project my-project [--region us-central1] [--dry-run]
set -euo pipefail

PROJECT=""
REGION="us-central1"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

read_dotenv_value() {
  # read_dotenv_value <file> <key> -- prints the value, or nothing.
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 | cut -d'=' -f2- | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

prompt_value() {
  # prompt_value <prompt> [<default>] -- echoes the resolved value.
  local prompt="$1" default="${2:-}"
  local entered
  if [[ -n "$default" ]]; then
    read -r -p "  ${prompt} [${default}]: " entered
    echo "${entered:-$default}"
  else
    read -r -p "  ${prompt}: " entered
    echo "$entered"
  fi
}

prompt_secret() {
  local prompt="$1"
  local entered
  read -r -s -p "  ${prompt}: " entered
  echo >&2
  echo "$entered"
}

if [[ -z "$PROJECT" ]]; then
  PROJECT="$(prompt_value 'Enter GOOGLE_CLOUD_PROJECT')"
fi

compute_sa() {
  local project_number
  project_number="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')"
  echo "${project_number}-compute@developer.gserviceaccount.com"
}
SA="$(compute_sa)"

set_deployment_secret() {
  # set_deployment_secret <name> <value>
  local name="$1" value="$2"
  if gcloud secrets describe "$name" --project="$PROJECT" >/dev/null 2>&1; then
    echo "  Secret '$name' already exists -- reusing its current value." >&2
    return 0
  fi
  if $DRY_RUN; then
    echo "  [DRY RUN] gcloud secrets create $name --project=$PROJECT --data-file=<value>" >&2
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  printf '%s' "$value" > "$tmp"
  gcloud secrets create "$name" --project="$PROJECT" --replication-policy=automatic --data-file="$tmp" >/dev/null
  rm -f "$tmp"
}

grant_secret_access() {
  local name="$1"
  if $DRY_RUN; then
    echo "  [DRY RUN] gcloud secrets add-iam-policy-binding $name --member=serviceAccount:$SA --role=roles/secretmanager.secretAccessor" >&2
    return 0
  fi
  gcloud secrets add-iam-policy-binding "$name" --project="$PROJECT" --member="serviceAccount:${SA}" --role="roles/secretmanager.secretAccessor" >/dev/null
}

get_service_url() {
  local service="$1"
  gcloud run services describe "$service" --region="$REGION" --project="$PROJECT" --format='value(status.url)'
}

run_deploy() {
  # run_deploy <service> <source_dir> <extra_args...> -- prints the deployed URL.
  local service="$1" source_dir="$2"
  shift 2
  local extra_args=("$@")
  if $DRY_RUN; then
    echo "  [DRY RUN] gcloud run deploy $service --source $source_dir --region=$REGION --project=$PROJECT --allow-unauthenticated --timeout=600 ${extra_args[*]}" >&2
    echo "https://${service}-dry-run-placeholder.a.run.app"
    return 0
  fi
  echo "  Running: gcloud run deploy $service --source $source_dir --region=$REGION --project=$PROJECT --allow-unauthenticated --timeout=600 ${extra_args[*]}" >&2
  gcloud run deploy "$service" --source "$source_dir" --region="$REGION" --project="$PROJECT" --allow-unauthenticated --timeout=600 "${extra_args[@]}" >&2
  get_service_url "$service"
}

# --- 1. DCR/procurement handler (dcr/) ---
echo
echo "=== 1/2: cyera-dataport-dcr ==="
DCR_DIR="${SCRIPT_DIR}/dcr"
DCR_ENV_FILE="${DCR_DIR}/.env"
DCR_SERVICE="cyera-dataport-dcr"

REDIRECT_URI="$(read_dotenv_value "$DCR_ENV_FILE" GEMINI_ENTERPRISE_REDIRECT_URI)"
OIDC_REG_ENDPOINT="$(read_dotenv_value "$DCR_ENV_FILE" OIDC_REGISTRATION_ENDPOINT)"
OIDC_REG_ENDPOINT="${OIDC_REG_ENDPOINT:-https://oidc.cyera.io/oidc/reg}"

echo "  Phase 1/2: deploying ${DCR_SERVICE} (learning its URL)..."
DCR_URL="$(run_deploy "$DCR_SERVICE" "$DCR_DIR" --set-env-vars "OIDC_REGISTRATION_ENDPOINT=${OIDC_REG_ENDPOINT},GEMINI_ENTERPRISE_REDIRECT_URI=${REDIRECT_URI}")"

echo "  Phase 2/2: redeploying ${DCR_SERVICE} with DCR_PROVIDER_URL set..."
DCR_URL="$(run_deploy "$DCR_SERVICE" "$DCR_DIR" --set-env-vars "OIDC_REGISTRATION_ENDPOINT=${OIDC_REG_ENDPOINT},GEMINI_ENTERPRISE_REDIRECT_URI=${REDIRECT_URI},DCR_PROVIDER_URL=${DCR_URL}/dcr")"
echo "cyera-dataport-dcr deployed: ${DCR_URL}"

# --- 2. Agent service (this directory) ---
echo
echo "=== 2/2: cyera-dataport-agent-marketplace ==="
AGENT_ENV_FILE="${SCRIPT_DIR}/.env"
AGENT_SERVICE="cyera-dataport-agent-marketplace"

MCP_TOKEN="$(read_dotenv_value "$AGENT_ENV_FILE" CYERA_DATAPORT_MCP_TOKEN)"
if [[ -z "$MCP_TOKEN" ]]; then
  MCP_TOKEN="$(prompt_secret 'Enter CYERA_DATAPORT_MCP_TOKEN')"
fi
MCP_SECRET_NAME="${AGENT_SERVICE}-mcp-token"
set_deployment_secret "$MCP_SECRET_NAME" "$MCP_TOKEN"
grant_secret_access "$MCP_SECRET_NAME"

API_KEY="$(read_dotenv_value "$AGENT_ENV_FILE" GOOGLE_API_KEY)"
if [[ -n "$API_KEY" ]]; then
  API_KEY_SECRET_NAME="${AGENT_SERVICE}-google-api-key"
  set_deployment_secret "$API_KEY_SECRET_NAME" "$API_KEY"
  grant_secret_access "$API_KEY_SECRET_NAME"
  MODEL_ENV_VARS="GOOGLE_CLOUD_PROJECT=${PROJECT}"
  MODEL_SECRETS_ARG="GOOGLE_API_KEY=${API_KEY_SECRET_NAME}:latest"
else
  MODEL_ENV_VARS="GOOGLE_GENAI_USE_VERTEXAI=true,GOOGLE_CLOUD_PROJECT=${PROJECT},GOOGLE_CLOUD_LOCATION=${REGION}"
  MODEL_SECRETS_ARG=""
fi

OIDC_ISSUER="$(read_dotenv_value "$AGENT_ENV_FILE" OIDC_ISSUER)"
OIDC_ISSUER="${OIDC_ISSUER:-https://oidc.cyera.io}"
OIDC_JWKS_URI="$(read_dotenv_value "$AGENT_ENV_FILE" OIDC_JWKS_URI)"
OIDC_JWKS_URI="${OIDC_JWKS_URI:-https://oidc.cyera.io/oidc/jwks}"
OAUTH_AUDIENCE="$(read_dotenv_value "$AGENT_ENV_FILE" OAUTH_AUDIENCE)"

BASE_ENV_VARS="${MODEL_ENV_VARS},OIDC_ISSUER=${OIDC_ISSUER},OIDC_JWKS_URI=${OIDC_JWKS_URI},DCR_TARGET_URL=${DCR_URL}/dcr"
if [[ -n "$OAUTH_AUDIENCE" ]]; then
  BASE_ENV_VARS="${BASE_ENV_VARS},OAUTH_AUDIENCE=${OAUTH_AUDIENCE}"
fi
SECRETS_ARG="CYERA_DATAPORT_MCP_TOKEN=${MCP_SECRET_NAME}:latest"
if [[ -n "$MODEL_SECRETS_ARG" ]]; then
  SECRETS_ARG="${SECRETS_ARG},${MODEL_SECRETS_ARG}"
fi

echo "  Phase 1/2: deploying ${AGENT_SERVICE} (learning its URL)..."
AGENT_URL="$(run_deploy "$AGENT_SERVICE" "$SCRIPT_DIR" --set-secrets "$SECRETS_ARG" --set-env-vars "$BASE_ENV_VARS")"

HOST_NAME="${AGENT_URL#http://}"
HOST_NAME="${HOST_NAME#https://}"
HOST_NAME="${HOST_NAME%/}"
PHASE2_ENV_VARS="${BASE_ENV_VARS},A2A_HOST=${HOST_NAME},A2A_PORT=443,A2A_PROTOCOL=https"

echo "  Phase 2/2: redeploying ${AGENT_SERVICE} with A2A_HOST set..."
AGENT_URL="$(run_deploy "$AGENT_SERVICE" "$SCRIPT_DIR" --set-secrets "$SECRETS_ARG" --set-env-vars "$PHASE2_ENV_VARS")"
echo "cyera-dataport-agent-marketplace deployed: ${AGENT_URL}"

echo
echo "Agent Card: ${AGENT_URL}/.well-known/agent-card.json"
echo "DCR endpoint: ${DCR_URL}/dcr"
echo
echo "See README.md 'What still requires your own action' before submitting this to Marketplace."
