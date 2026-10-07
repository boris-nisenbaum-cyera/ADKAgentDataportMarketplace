<#
.SYNOPSIS
  Deploys the Marketplace-packaged Cyera Dataport agent (this directory)
  and its companion DCR/procurement handler (dcr/) to Cloud Run.

.DESCRIPTION
  Self-contained deploy script for THIS directory only -- deliberately
  NOT integrated into ../Deployment_artifacts/deploy.ps1, per the
  instruction that created this whole directory ("do not modify any
  existing code, create a separate directory for new artifacts"). Mirrors
  that script's own conventions (env-file-then-prompt config resolution,
  Secret Manager for credentials, a two-phase deploy to solve the
  "service needs its own URL baked into its config" problem) rather than
  inventing new ones, but is independent of it.

  Two Cloud Run services, deployed in this order (each solves the other's
  "don't know my own URL yet" problem via a two-phase deploy, same
  pattern as every other A2A agent in this project):
    1. cyera-dataport-dcr (dcr/) -- deployed twice: once to learn its own
       URL, then again with DCR_PROVIDER_URL set to it (needed to verify
       Google's Marketplace DCR JWT's `aud` claim -- see dcr/utils.py).
    2. cyera-dataport-agent-marketplace (this directory) -- deployed
       twice: once to learn its own URL, then again with
       A2A_HOST/A2A_PORT/A2A_PROTOCOL (so its Agent Card advertises the
       real address, same as every other A2A agent here) AND
       DCR_TARGET_URL set to the DCR service's real URL from step 1.

  This script does NOT create a Marketplace listing, register as a Cloud
  Build Partner, or obtain a real Pub/Sub topic/providerId -- those are
  genuinely external actions only Cyera itself can take. See README.md.

.PARAMETER Project
  GCP project ID. If omitted, prompted for.

.PARAMETER Region
  Cloud Run region. Default: us-central1.

.PARAMETER DryRun
  Print every gcloud command this script would run, execute none of them.

.EXAMPLE
  .\deploy.ps1 -Project my-project
#>
[CmdletBinding()]
param(
    [string]$Project,
    [string]$Region = "us-central1",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$Script:DryRun = [bool]$DryRun
$Script:ScriptRoot = $PSScriptRoot

function Read-DotEnvFile {
    param([string]$Path)
    $result = @{}
    if (-not (Test-Path $Path)) { return $result }
    foreach ($line in Get-Content -Path $Path) {
        $trimmed = $line.Trim()
        if ($trimmed -eq "" -or $trimmed.StartsWith("#")) { continue }
        $idx = $trimmed.IndexOf("=")
        if ($idx -lt 1) { continue }
        $key = $trimmed.Substring(0, $idx).Trim()
        $value = $trimmed.Substring($idx + 1).Trim()
        if ($value.Length -ge 2) {
            $isDouble = $value.StartsWith('"') -and $value.EndsWith('"')
            $isSingle = $value.StartsWith("'") -and $value.EndsWith("'")
            if ($isDouble -or $isSingle) { $value = $value.Substring(1, $value.Length - 2) }
        }
        if ($value -ne "") { $result[$key] = $value }
    }
    return $result
}

function Resolve-ConfigValue {
    param([hashtable]$EnvTable, [string]$Key, [string]$Default = $null, [switch]$Secret, [switch]$Silent)
    if ($EnvTable -and $EnvTable.ContainsKey($Key) -and $EnvTable[$Key]) { return $EnvTable[$Key] }
    if ($Silent) { return $Default }
    if ($Secret) {
        $secure = Read-Host -Prompt "  Enter $Key" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    if ($Default) {
        $entered = Read-Host -Prompt "  Enter $Key [$Default]"
        if ([string]::IsNullOrWhiteSpace($entered)) { return $Default }
        return $entered
    }
    return (Read-Host -Prompt "  Enter $Key")
}

function Get-ComputeServiceAccount {
    param([string]$Project)
    $projectNumber = (& gcloud projects describe $Project --format="value(projectNumber)")
    return "$projectNumber-compute@developer.gserviceaccount.com"
}

function Set-DeploymentSecret {
    param([string]$Name, [string]$Project, [string]$Value)
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & gcloud secrets describe $Name --project=$Project 2>$null | Out-Null
    $exists = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prevPref
    if ($exists) {
        Write-Host "  Secret '$Name' already exists -- reusing its current value." -ForegroundColor DarkGray
        return
    }
    if ($Script:DryRun) {
        Write-Host "  [DRY RUN] gcloud secrets create $Name --project=$Project --data-file=<value>"
        return
    }
    $tmp = New-TemporaryFile
    try {
        Set-Content -Path $tmp -NoNewline -Value $Value
        & gcloud secrets create $Name --project=$Project --replication-policy=automatic --data-file="$tmp" | Out-Null
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
}

function Grant-SecretAccess {
    param([string]$Name, [string]$Project, [string]$ServiceAccount)
    if ($Script:DryRun) {
        Write-Host "  [DRY RUN] gcloud secrets add-iam-policy-binding $Name --member=serviceAccount:$ServiceAccount --role=roles/secretmanager.secretAccessor"
        return
    }
    & gcloud secrets add-iam-policy-binding $Name --project=$Project --member="serviceAccount:$ServiceAccount" --role="roles/secretmanager.secretAccessor" | Out-Null
}

function Get-ServiceUrl {
    param([string]$Service, [string]$Region, [string]$Project)
    return (& gcloud run services describe $Service --region=$Region --project=$Project --format="value(status.url)")
}

function Invoke-RunDeploy {
    param(
        [string]$Service, [string]$SourceDir, [string]$Region, [string]$Project,
        [string[]]$ExtraArgs = @(), [int]$TimeoutSeconds = 600
    )
    # This agent is deliberately --allow-unauthenticated: its own inbound
    # gate is oauth_middleware.py's OAuth2 Bearer-token check (Marketplace
    # end-user credentials, not Cyera GCP IAM principals) -- see
    # oauth_middleware.py's module docstring for why this differs from
    # every other agent in this project (../ADKAgentDataport included),
    # which use Cloud Run's own IAM invoker gate instead.
    $gcloudArgs = @("run", "deploy", $Service, "--source", $SourceDir, "--region", $Region, "--project", $Project, "--allow-unauthenticated", "--timeout=$TimeoutSeconds") + $ExtraArgs
    if ($Script:DryRun) {
        Write-Host "  [DRY RUN] gcloud $($gcloudArgs -join ' ')"
        return "https://$Service-dry-run-placeholder.a.run.app"
    }
    Write-Host "  Running: gcloud $($gcloudArgs -join ' ')" -ForegroundColor Cyan
    & gcloud @gcloudArgs
    if ($LASTEXITCODE -ne 0) { throw "gcloud run deploy failed for service '$Service' (exit code $LASTEXITCODE)." }
    return (Get-ServiceUrl -Service $Service -Region $Region -Project $Project)
}

if (-not $Project) {
    $Project = Resolve-ConfigValue -EnvTable @{} -Key "GOOGLE_CLOUD_PROJECT"
}

$sa = Get-ComputeServiceAccount -Project $Project

# --- 1. DCR/procurement handler (dcr/) ---
Write-Host "`n=== 1/2: cyera-dataport-dcr ===" -ForegroundColor Magenta
$dcrDir = Join-Path $Script:ScriptRoot "dcr"
$dcrEnvFile = Join-Path $dcrDir ".env"
$dcrEnvTable = Read-DotEnvFile -Path $dcrEnvFile
$dcrService = "cyera-dataport-dcr"

$redirectUri = Resolve-ConfigValue -EnvTable $dcrEnvTable -Key "GEMINI_ENTERPRISE_REDIRECT_URI" -Default "" -Silent
$oidcRegEndpoint = Resolve-ConfigValue -EnvTable $dcrEnvTable -Key "OIDC_REGISTRATION_ENDPOINT" -Default "https://oidc.cyera.io/oidc/reg" -Silent

Write-Host "  Phase 1/2: deploying $dcrService (learning its URL)..." -ForegroundColor Cyan
$dcrUrl = Invoke-RunDeploy -Service $dcrService -SourceDir $dcrDir -Region $Region -Project $Project `
    -ExtraArgs @("--set-env-vars", "OIDC_REGISTRATION_ENDPOINT=$oidcRegEndpoint,GEMINI_ENTERPRISE_REDIRECT_URI=$redirectUri")

Write-Host "  Phase 2/2: redeploying $dcrService with DCR_PROVIDER_URL set..." -ForegroundColor Cyan
$dcrUrl = Invoke-RunDeploy -Service $dcrService -SourceDir $dcrDir -Region $Region -Project $Project `
    -ExtraArgs @("--set-env-vars", "OIDC_REGISTRATION_ENDPOINT=$oidcRegEndpoint,GEMINI_ENTERPRISE_REDIRECT_URI=$redirectUri,DCR_PROVIDER_URL=$dcrUrl/dcr")
Write-Host "cyera-dataport-dcr deployed: $dcrUrl" -ForegroundColor Green

# --- 2. Agent service (this directory) ---
Write-Host "`n=== 2/2: cyera-dataport-agent-marketplace ===" -ForegroundColor Magenta
$agentEnvFile = Join-Path $Script:ScriptRoot ".env"
$agentEnvTable = Read-DotEnvFile -Path $agentEnvFile
$agentService = "cyera-dataport-agent-marketplace"

$mcpToken = Resolve-ConfigValue -EnvTable $agentEnvTable -Key "CYERA_DATAPORT_MCP_TOKEN" -Secret
$mcpSecretName = "$agentService-mcp-token"
Set-DeploymentSecret -Name $mcpSecretName -Project $Project -Value $mcpToken
Grant-SecretAccess -Name $mcpSecretName -Project $Project -ServiceAccount $sa

$apiKey = Resolve-ConfigValue -EnvTable $agentEnvTable -Key "GOOGLE_API_KEY" -Default $null -Silent
$modelEnvVars = ""
$modelSecretsArg = ""
if ($apiKey) {
    $apiKeySecretName = "$agentService-google-api-key"
    Set-DeploymentSecret -Name $apiKeySecretName -Project $Project -Value $apiKey
    Grant-SecretAccess -Name $apiKeySecretName -Project $Project -ServiceAccount $sa
    $modelEnvVars = "GOOGLE_CLOUD_PROJECT=$Project"
    $modelSecretsArg = "GOOGLE_API_KEY=${apiKeySecretName}:latest"
} else {
    $modelEnvVars = "GOOGLE_GENAI_USE_VERTEXAI=true,GOOGLE_CLOUD_PROJECT=$Project,GOOGLE_CLOUD_LOCATION=$Region"
}

$oidcIssuer = Resolve-ConfigValue -EnvTable $agentEnvTable -Key "OIDC_ISSUER" -Default "https://oidc.cyera.io" -Silent
$oidcJwksUri = Resolve-ConfigValue -EnvTable $agentEnvTable -Key "OIDC_JWKS_URI" -Default "https://oidc.cyera.io/oidc/jwks" -Silent
$oauthAudience = Resolve-ConfigValue -EnvTable $agentEnvTable -Key "OAUTH_AUDIENCE" -Default "" -Silent

$baseEnvVars = "$modelEnvVars,OIDC_ISSUER=$oidcIssuer,OIDC_JWKS_URI=$oidcJwksUri,DCR_TARGET_URL=$dcrUrl/dcr"
if ($oauthAudience) { $baseEnvVars = "$baseEnvVars,OAUTH_AUDIENCE=$oauthAudience" }
$secretsArg = "CYERA_DATAPORT_MCP_TOKEN=${mcpSecretName}:latest"
if ($modelSecretsArg) { $secretsArg = "$secretsArg,$modelSecretsArg" }

Write-Host "  Phase 1/2: deploying $agentService (learning its URL)..." -ForegroundColor Cyan
$agentUrl = Invoke-RunDeploy -Service $agentService -SourceDir $Script:ScriptRoot -Region $Region -Project $Project `
    -ExtraArgs @("--set-secrets", $secretsArg, "--set-env-vars", $baseEnvVars)

$hostName = ($agentUrl -replace '^https?://', '').TrimEnd('/')
$phase2EnvVars = "$baseEnvVars,A2A_HOST=$hostName,A2A_PORT=443,A2A_PROTOCOL=https"

Write-Host "  Phase 2/2: redeploying $agentService with A2A_HOST set..." -ForegroundColor Cyan
$agentUrl = Invoke-RunDeploy -Service $agentService -SourceDir $Script:ScriptRoot -Region $Region -Project $Project `
    -ExtraArgs @("--set-secrets", $secretsArg, "--set-env-vars", $phase2EnvVars)
Write-Host "cyera-dataport-agent-marketplace deployed: $agentUrl" -ForegroundColor Green

Write-Host "`nAgent Card: $agentUrl/.well-known/agent-card.json" -ForegroundColor Green
Write-Host "DCR endpoint: $dcrUrl/dcr" -ForegroundColor Green
Write-Host "`nSee README.md 'What still requires your own action' before submitting this to Marketplace." -ForegroundColor Yellow
