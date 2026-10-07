# ADKAgentDataportMarketplace

Repackaging of [`../ADKAgentDataport`](../ADKAgentDataport) for listing as a
Google Cloud Marketplace "Agent-as-a-Service" (AaaS), following the pattern
documented at
[`ljogeiger/GE-A2A-Marketplace-Agent`](https://github.com/ljogeiger/GE-A2A-Marketplace-Agent).

**No file in `../ADKAgentDataport` was modified.** This is a separate,
self-contained directory: `agent.py`, `__init__.py`, and `auth_context.py`
are verbatim copies of that agent's own logic; everything else here
(`main.py`, `oauth_middleware.py`, `agent-card.json`, `dcr/`) is new,
written specifically for the Marketplace requirements below.

## Why this is a separate package, not a config change to the original

`../ADKAgentDataport` is gated by Google Identity Platform tokens and Cloud
Run IAM (see its own `auth_middleware.py`) -- both are Cyera-internal-GCP
concepts that only make sense for Cyera's own deployment, called by Cyera's
own Gemini Enterprise app. A Marketplace listing is procured and called by
*other organizations'* Gemini Enterprise instances, whose end users have no
Cyera GCP identity at all. Google's own AaaS requirements for that case are
different in kind, not degree:

- OAuth 2.0 Authorization Code Grant flow as the *only* supported caller
  auth method (no IAM, no static API keys).
- A published A2A Agent Card declaring that OAuth flow's real endpoints and
  scopes.
- Dynamic Client Registration (DCR, RFC 7591) so Gemini Enterprise can
  provision its own OAuth client per Marketplace order, without a human
  exchanging credentials by hand.
- Marketplace Procurement API + Pub/Sub integration, so a customer
  subscribing to the listing actually triggers that provisioning.

## What's fully implemented here (real, not a stub)

- **`agent.py`, `__init__.py`, `auth_context.py`** -- byte-identical copies
  of `../ADKAgentDataport`'s own agent logic. The Dataport MCP tool-calling
  behavior is unchanged.
- **`oauth_middleware.py`** -- verifies inbound `Authorization: Bearer`
  tokens as real OAuth2/OIDC access tokens: fetches JWKS from `jwks_uri`,
  verifies the signature, and checks `iss` (and, if `OAUTH_AUDIENCE` is
  set, `aud`). Defaults to Cyera's own real, live-confirmed OIDC provider
  (`https://oidc.cyera.io`, confirmed via
  `curl https://oidc.cyera.io/.well-known/openid-configuration`).
- **`agent-card.json`** -- a static Marketplace-shaped Agent Card with a
  real `securitySchemes.oauth2.flows.authorizationCode` pointing at Cyera's
  actual `authorizationUrl`/`tokenUrl` (`oidc.cyera.io/oidc/authorize` and
  `/oidc/token`), and a `capabilities.extensions[]` entry advertising the
  DCR endpoint below. `main.py` patches in this exact service's own URL and
  the DCR handler's URL at container startup (see its module docstring for
  why -- same "don't know my own URL until after first deploy" problem
  every other A2A agent in this project solves the same way).
- **`dcr/main.py` + `dcr/utils.py`** -- a Cloud Run service implementing
  the hybrid handler pattern from the reference repo:
  - Verifies Google's real Marketplace DCR `software_statement` JWT against
    Google's own published public keys
    (`https://www.googleapis.com/service_accounts/v1/metadata/x509/cloud-agentspace@system.gserviceaccount.com`).
  - On a genuine Pub/Sub `ACCOUNT_CREATION_REQUESTED` event, approves the
    order via Google's real Procurement API
    (`cloudcommerceprocurement.googleapis.com/v1/{resource}:approve`) using
    this service's own ambient Cloud Run credentials.
  - Registers a new OAuth client via `register_oidc_client()` -- a
    **generic RFC 7591 POST to `oidc.cyera.io/oidc/reg`**, Cyera's own
    live-confirmed Dynamic Client Registration endpoint. This replaces the
    reference repo's Okta-specific admin API call; Cyera's own IdP
    natively speaks the standard, so no proprietary integration is needed.
  - Persists `{order_id -> client_id, client_secret}` in Firestore
    (`marketplace_clients` collection), and serves it back on the
    synchronous DCR path.
- **`deploy.ps1` / `deploy.sh`** -- deploy both Cloud Run services
  (`cyera-dataport-dcr` and `cyera-dataport-agent-marketplace`), each via a
  two-phase deploy so their real URLs get baked into each other's config
  (DCR needs its own URL for JWT audience checks; the agent needs the DCR
  URL for its Agent Card's DCR extension).
- **`setup_firestore.ps1` / `setup_firestore.sh`** -- one-time Firestore
  database provisioning for the DCR handler's persistence.

## What still requires Cyera's own action (cannot be done from here)

None of the following has an API this assistant can call on Cyera's
behalf -- each is either an external business process or requires a
decision only a Cyera stakeholder can make:

1. **Becoming a Google Cloud Marketplace Partner** and creating the actual
   "AI Agent as a Service" listing in the Producer Portal. This is what
   creates the real Marketplace `providerId`, the Pub/Sub topic this
   `dcr/` service should subscribe to, and the `GEMINI_ENTERPRISE_REDIRECT_URI`
   this package currently leaves blank in `dcr/.env.example`. Nothing here
   works end-to-end until that listing exists.
2. **Wiring the real Pub/Sub subscription** to `dcr/main.py`'s `/dcr`
   endpoint (a push subscription pointing at this Cloud Run service) --
   only possible once step 1 provides the topic.
3. **Confirming with whoever administers `oidc.cyera.io`** that its
   `/oidc/reg` registration endpoint is permitted for this external,
   Marketplace-driven client-registration use case, and that its
   `redirect_uris` validation will accept whatever URI Gemini Enterprise
   provides once step 1 exists. This has been verified to be a real,
   spec-compliant endpoint, but never exercised end-to-end for this
   purpose.
4. **Running the Procurement API's one-time account setup**
   (`gcloud services enable cloudcommerceprocurement.googleapis.com` and
   the associated account-registration call Google's own Marketplace
   onboarding docs describe) -- a prerequisite for step 1, not something
   this package can trigger.
5. **Deciding `OAUTH_AUDIENCE`** -- left unset (no audience check) by
   default in `oauth_middleware.py` until a real Marketplace OAuth client
   registration exists to define what value that should be.

## Local testing

```
python -m venv .venv && .venv\Scripts\activate   # or: source .venv/bin/activate
pip install -r requirements.txt
copy .env.example .env   # fill in CYERA_DATAPORT_MCP_TOKEN and a model credential
python main.py
```

Without a valid Bearer token, every request except
`/.well-known/agent-card.json` gets a 401 from `oauth_middleware.py` -- this
is expected; there is no local bypass, matching this project's convention
of never weakening a security gate for convenience.

## Code map

| File | Purpose |
|---|---|
| `agent.py`, `__init__.py`, `auth_context.py` | Verbatim copy of `../ADKAgentDataport`'s agent logic |
| `main.py` | A2A app entrypoint; loads/patches `agent-card.json`, attaches `oauth_middleware.py` |
| `oauth_middleware.py` | OAuth2/OIDC Bearer-token verification (JWKS-based) |
| `agent-card.json` | Static Marketplace-shaped A2A Agent Card |
| `dcr/main.py` | DCR + Marketplace Procurement Pub/Sub handler (separate Cloud Run service) |
| `dcr/utils.py` | Google DCR JWT verification, Firestore persistence, RFC 7591 registration against `oidc.cyera.io` |
| `deploy.ps1` / `deploy.sh` | Deploys both services |
| `setup_firestore.ps1` / `setup_firestore.sh` | One-time Firestore setup |
