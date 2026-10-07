# Deployment Instructions -- ADKAgentDataportMarketplace

Step-by-step guide to running this directory's own `deploy.ps1` / `deploy.sh`
and `setup_firestore.ps1` / `setup_firestore.sh`, and exactly which
parameters and `.env` keys need to be filled in at deployment time. This
document describes the scripts as they exist today in this directory --
it does not add, change, or fix anything in them (see `README.md` for the
broader picture of what this package is and what still requires Cyera's
own external action before a real Marketplace listing works end-to-end).

## What gets deployed

Two independent Cloud Run services, in this order:

1. **`cyera-dataport-dcr`** -- built from `dcr/`. Handles Google's
   Marketplace Dynamic Client Registration (DCR) calls and Pub/Sub
   procurement events.
2. **`cyera-dataport-agent-marketplace`** -- built from this directory's
   own root. The A2A agent itself.

Both scripts deploy each service **twice** (a "two-phase deploy"): the
first deploy learns the service's own real Cloud Run URL, then a second
deploy re-runs with that URL baked into the service's env vars (the DCR
service needs to know its own URL to verify Google's JWT audience; the
agent needs the DCR service's URL for its Agent Card, and its own URL for
the Agent Card's `url` field). This is automatic and requires no action
from you beyond waiting for both deploys to finish -- it is not something
you need to run twice yourself.

## Prerequisites

Confirm these before running anything:

1. **`gcloud` CLI installed and authenticated**, with access to the
   target project:
   ```
   gcloud auth login
   gcloud auth application-default login
   ```
2. **Required GCP APIs already enabled** on the target project. Neither
   `deploy.ps1`/`deploy.sh` nor `setup_firestore.ps1`/`.sh` enable these
   for you (unlike `../Deployment_artifacts/deploy.ps1`, which does) --
   enable them yourself first if this is a project that hasn't run any
   of this project's other deploy scripts before:
   ```
   gcloud services enable run.googleapis.com cloudbuild.googleapis.com secretmanager.googleapis.com firestore.googleapis.com --project=YOUR_PROJECT_ID
   ```
3. **IAM permissions** on that project: enough to create Cloud Run
   services, Secret Manager secrets, and (for the one-time Firestore
   step) a Firestore database -- `roles/editor`, or the narrower
   combination of `roles/run.admin`, `roles/secretmanager.admin`, and
   `roles/datastore.owner`.
4. **A valid `CYERA_DATAPORT_MCP_TOKEN`** (see `.env.example`'s own
   comment for how to obtain/verify one) and either a `GOOGLE_API_KEY`
   (AI Studio) or Vertex AI access in the target project.

## Step 1 -- one-time Firestore setup

The DCR service persists `{order_id -> client_id, client_secret}`
mappings in Firestore. Run this **once per project** before the first
deploy:

**PowerShell:**
```powershell
.\setup_firestore.ps1 -Project YOUR_PROJECT_ID
```

**Bash:**
```bash
./setup_firestore.sh --project YOUR_PROJECT_ID
```

| Parameter | PowerShell flag | Bash flag | Default | Notes |
|---|---|---|---|---|
| GCP project ID | `-Project` | `--project` | none -- prompted if omitted | Same project you'll pass to `deploy.ps1`/`deploy.sh` |
| Firestore location | `-Region` | `--region` | `nam5` | A Firestore **location** (e.g. `nam5`, `eur3`), NOT necessarily the same value as the Cloud Run `region` used below -- Firestore uses its own location naming scheme |

Safe to re-run -- if a database already exists, the script reports
`ALREADY_EXISTS` and treats that as success, not an error. The
`marketplace_clients` collection itself is created lazily on first write,
not by this script.

## Step 2 -- configure `.env` files

Two separate `.env` files control deployment-time values: one for the
agent service (this directory's own root) and one for the DCR service
(`dcr/`). Copy each `.env.example` to `.env` in the same folder and fill
in real values:

```powershell
Copy-Item .env.example .env
Copy-Item dcr\.env.example dcr\.env
```

### 2a. Agent service -- `ADKAgentDataportMarketplace/.env`

| Key | Read by the deploy scripts? | Required? | Default if omitted |
|---|---|---|---|
| `CYERA_DATAPORT_MCP_TOKEN` | Yes | **Yes** | None -- if missing from `.env`, both scripts prompt for it interactively (masked input) at deploy time |
| `GOOGLE_API_KEY` | Yes | No | If unset, the script configures Vertex AI instead (`GOOGLE_GENAI_USE_VERTEXAI=true`, using the `-Project`/`-Region` (or `--project`/`--region`) values you pass on the command line, not any `.env` value) |
| `OIDC_ISSUER` | Yes | No | `https://oidc.cyera.io` |
| `OIDC_JWKS_URI` | Yes | No | `https://oidc.cyera.io/oidc/jwks` |
| `OAUTH_AUDIENCE` | Yes | No | Unset (no audience check performed) |
| `CYERA_DATAPORT_MCP_URL` | **No** | No | See "Known gaps" below |
| `ADK_MODEL` | **No** | No | See "Known gaps" below |
| `THINKING_BUDGET` | **No** | No | See "Known gaps" below |
| `GOOGLE_CLOUD_LOCATION` (Vertex path) | **No** | No | Always taken from the `-Region`/`--region` deploy parameter instead, even if set differently in `.env` |
| `A2A_HOST` / `A2A_PORT` / `A2A_PROTOCOL` | **No** (always recomputed) | -- | Always overwritten by the script itself from the real, just-deployed Cloud Run URL -- any value you put in `.env` for these is ignored during a scripted deploy |
| `DCR_TARGET_URL` | **No** (always recomputed) | -- | Always overwritten with the DCR service's real, just-deployed URL |
| `PORT` | N/A | No | Not applicable to Cloud Run deploys -- Cloud Run injects `PORT` itself |

### 2b. DCR service -- `ADKAgentDataportMarketplace/dcr/.env`

| Key | Read by the deploy scripts? | Required? | Default if omitted |
|---|---|---|---|
| `GEMINI_ENTERPRISE_REDIRECT_URI` | Yes | No (but see below) | Empty string. The deploy succeeds either way, but a real OAuth flow cannot work until this is set to the real value Google's Marketplace Producer Portal gives you once your listing exists (see `README.md`) |
| `OIDC_REGISTRATION_ENDPOINT` | Yes | No | `https://oidc.cyera.io/oidc/reg` |
| `DCR_PROVIDER_URL` | **No** (always recomputed) | -- | Always overwritten with the DCR service's own real, just-deployed URL (`<url>/dcr`) -- any value in `.env` is ignored during a scripted deploy; this key in `.env.example` is only meaningful for a manual local run (`python dcr/main.py`) |
| `PORT` | N/A | No | Not applicable to Cloud Run -- Cloud Run injects `PORT` itself |

### Known gaps -- `.env` keys the deploy scripts do not forward

`CYERA_DATAPORT_MCP_URL`, `ADK_MODEL`, and `THINKING_BUDGET` are all
documented as valid overrides in `.env.example`'s comments, but neither
`deploy.ps1` nor `deploy.sh` currently reads or forwards any of the
three to the deployed Cloud Run service -- confirmed by inspecting both
scripts directly, not assumed. Setting them in `.env` has **no effect**
on a deploy run through these scripts.

If you need one of these set, add it after deploying, e.g.:
```
gcloud run services update cyera-dataport-agent-marketplace --region=YOUR_REGION --project=YOUR_PROJECT_ID --update-env-vars=ADK_MODEL=claude-sonnet-5
```
Note this only adds/overwrites the given key(s) (`--update-env-vars`,
not `--set-env-vars`) -- it will not wipe out `A2A_HOST` or the other
values the deploy script already set.

## Step 3 -- run the deploy

**PowerShell:**
```powershell
.\deploy.ps1 -Project YOUR_PROJECT_ID -Region us-central1
```

**Bash:**
```bash
./deploy.sh --project YOUR_PROJECT_ID --region us-central1
```

| Parameter | PowerShell flag | Bash flag | Default | Notes |
|---|---|---|---|---|
| GCP project ID | `-Project` | `--project` | none -- prompted if omitted | Must have the prerequisite APIs already enabled (Step 0) |
| Cloud Run region | `-Region` | `--region` | `us-central1` | Used for both Cloud Run services |
| Preview only, no changes | `-DryRun` | `--dry-run` | off | Prints every `gcloud` command that would run, including the exact `--set-env-vars`/`--set-secrets` values, without executing any of them. **Recommended on the first run in any new project** |

Recommended sequence:
```powershell
.\deploy.ps1 -Project YOUR_PROJECT_ID -DryRun    # review the printed commands first
.\deploy.ps1 -Project YOUR_PROJECT_ID            # then run for real
```

### What happens during the run

1. Deploys `cyera-dataport-dcr` (phase 1), reads its new URL.
2. Redeploys `cyera-dataport-dcr` (phase 2) with `DCR_PROVIDER_URL` set
   to that URL.
3. Resolves `CYERA_DATAPORT_MCP_TOKEN` (from `.env`, or an interactive
   masked prompt) and creates/reuses a Secret Manager secret for it,
   granting the project's compute default service account
   `roles/secretmanager.secretAccessor` on it.
4. If `GOOGLE_API_KEY` is set, does the same for it; otherwise
   configures the Vertex AI env vars instead.
5. Deploys `cyera-dataport-agent-marketplace` (phase 1), reads its new
   URL.
6. Redeploys it (phase 2) with `A2A_HOST`/`A2A_PORT`/`A2A_PROTOCOL` set
   to that URL.
7. Prints the Agent Card URL and DCR endpoint URL.

### Secret handling and re-running the script

`Set-DeploymentSecret`/`set_deployment_secret` **only create a Secret
Manager secret if one by that name doesn't already exist** -- re-running
the deploy script after a token has changed does **not** rotate it. To
update `CYERA_DATAPORT_MCP_TOKEN` (or `GOOGLE_API_KEY`) after the secret
already exists, either:
- Add a new version manually:
  ```
  echo -n "NEW_TOKEN_VALUE" | gcloud secrets versions add cyera-dataport-agent-marketplace-mcp-token --project=YOUR_PROJECT_ID --data-file=-
  ```
  (Cloud Run always reads `:latest`, so this takes effect on the next
  deploy/revision without any script change), or
- Delete the secret first (`gcloud secrets delete ...`) and re-run the
  deploy script, which will then create it fresh from the current
  `.env`/prompt value.

## Verifying the deploy

```powershell
$agentUrl = <the "cyera-dataport-agent-marketplace deployed:" URL printed at the end>
Invoke-RestMethod -Uri "$agentUrl/.well-known/agent-card.json" | ConvertTo-Json -Depth 10
```

Confirm the `"url"` field is the real `https://cyera-dataport-agent-marketplace-....run.app/` address (not `localhost`), and that
`capabilities.extensions[0].params.target_url` points at the DCR
service's real `/dcr` URL, not a placeholder.

## After deploying

Both Cloud Run services are now live, but a real end-to-end Marketplace
flow additionally requires several things only Cyera itself can do
(becoming a Marketplace Partner, creating the actual listing, obtaining
a real Pub/Sub topic and `GEMINI_ENTERPRISE_REDIRECT_URI`, and confirming
`oidc.cyera.io`'s registration endpoint is permitted for this use) -- see
`README.md`'s "What still requires Cyera's own action" section for the
full list. This document only covers running the scripts as they exist
today; it does not change what they do.

## Troubleshooting

**Script prompts for `CYERA_DATAPORT_MCP_TOKEN` every time.** Expected if
it's not set in `.env` -- add it there to skip the prompt on future runs
(see Step 2a).

**`gcloud secrets create` fails with `PERMISSION_DENIED`.** Your account
needs `roles/secretmanager.admin` (or broader) on the target project.

**Deploy succeeds but the Agent Card still shows `localhost`.** You
interrupted the script between phase 1 and phase 2 of a deploy, or ran
only part of it manually. Re-run the full script -- both phases always
run together in one invocation, so a normal full run always ends with
the correct URL.

**Changed an `.env` value but it's not showing up in the deployed
service.** Check the "Known gaps" table above first -- three keys
(`CYERA_DATAPORT_MCP_URL`, `ADK_MODEL`, `THINKING_BUDGET`) are
documented in `.env.example` but not actually read by these scripts.

**`gcloud firestore databases create` fails with `API_NOT_ENABLED` (or
similar).** Run the `gcloud services enable firestore.googleapis.com`
command from Prerequisites, then re-run `setup_firestore.ps1`/`.sh`.
