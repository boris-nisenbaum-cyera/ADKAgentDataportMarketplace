"""A2A-compliant ASGI app for the Marketplace-packaged Cyera Dataport
agent, and its Cloud Run entrypoint.

Repackaging of ../ADKAgentDataport for listing on Google Cloud Marketplace
as an "Agent-as-a-Service", following the pattern documented at
https://github.com/ljogeiger/GE-A2A-Marketplace-Agent. See this
directory's own README.md for the full picture of what's implemented here
vs. what still requires Cyera's own action (Partner enrollment, an actual
Marketplace listing, and confirming oidc.cyera.io's registration endpoint
is usable for this).

WHY A STATIC agent-card.json, NOT ADK's OWN auto-built card
--------------------------------------------------------------------------
Every other agent in this project (../ADKAgentDataport included) lets
`to_a2a()` auto-generate its Agent Card from the LlmAgent object itself.
That auto-built card has no concept of OAuth2 securitySchemes or the
Marketplace-specific DCR extension (`capabilities.extensions[]` with the
`https://cloud.google.com/marketplace/docs/partners/ai-agents/setup-dcr`
URI) -- both are HARD REQUIREMENTS for a Marketplace listing (see the
reference repo's own README "A2A Agent Card" section). So this directory
instead ships a hand-authored agent-card.json (the Marketplace-required
shape) and loads THAT, patching in the two fields that can only be known
after this exact Cloud Run service is deployed (its own public URL, and
the DCR handler's own public URL) -- same "circular dependency" problem
../Deployment_artifacts/deploy.ps1 solves for every other agent's
auto-built card via a two-phase deploy; solved the same way here (see
deploy.ps1/deploy.sh in this directory), just patching a static file
instead of passing host/port to to_a2a() and letting it rebuild the card.

Two independent "port" concepts, do not conflate them (see
../ADKAgent/main.py's module docstring for the full explanation):
  - $PORT: Cloud Run's actual container listen port.
  - A2A_HOST / A2A_PORT / A2A_PROTOCOL: baked into the *public* Agent Card
    so Gemini Enterprise knows where to actually reach this service from
    outside.
"""
from __future__ import annotations

import json
import os
from pathlib import Path

import uvicorn
from a2a.types import AgentCard
from google.adk.a2a.utils.agent_to_a2a import to_a2a

from agent import root_agent
from oauth_middleware import OAuth2AuthMiddleware

# The OAuth2/OIDC provider that issues the end-user access tokens this
# agent verifies -- confirmed live (`curl https://oidc.cyera.io/.well-
# known/openid-configuration`) to be Cyera's own real OIDC provider,
# already used elsewhere in this project (see ../CyeraAnalyticsAgent's
# earlier custom-MCP-server-data-store OAuth config). Override only if
# this is ever deployed against a different Cyera environment/tenant.
OIDC_ISSUER = os.environ.get("OIDC_ISSUER", "https://oidc.cyera.io")
OIDC_JWKS_URI = os.environ.get("OIDC_JWKS_URI", "https://oidc.cyera.io/oidc/jwks")

# The audience this agent's own access tokens must carry -- set this to
# whatever Cyera's OIDC client configuration actually issues for THIS
# agent once real Marketplace client registrations exist (see
# dcr/main.py). Left unset by default (no audience check) rather than
# guessing a wrong value that would silently reject every real caller --
# see oauth_middleware.py's own docstring for the same "never infer
# security-sensitive config" convention used throughout this project.
OAUTH_AUDIENCE = os.environ.get("OAUTH_AUDIENCE") or None

_a2a_host = os.environ.get("A2A_HOST", "localhost")
_a2a_port = os.environ.get("A2A_PORT", "8080")
_a2a_protocol = os.environ.get("A2A_PROTOCOL", "http")

# The separately-deployed DCR/marketplace-procurement handler's own public
# URL (see ../dcr/main.py) -- baked into the agent card's DCR extension so
# Gemini Enterprise knows where to POST the software_statement JWT during
# registration. Left as a placeholder until that service is deployed too
# (deploy.ps1/deploy.sh fill this in, mirroring the same two-phase pattern
# used for this agent's own URL).
DCR_TARGET_URL = os.environ.get("DCR_TARGET_URL", "http://localhost:8081/dcr")


def _build_canonical_rpc_url(protocol: str, host: str, port: str) -> str:
    """Omits the port when it's the scheme's own default (443 for https, 80
    for http) -- see ../CyeraAnalyticsAgent/main.py's identical helper for
    the full, live-confirmed rationale: a URL like "https://host:443" is
    non-canonical and has caused real, live Cloud Run IAM-invoker
    rejections elsewhere in this project. Not strictly required here
    (this agent is Cloud Run `--allow-unauthenticated`, gated by its OWN
    OAuth2 middleware instead -- see README.md), but kept for consistency
    and because it costs nothing to be correct."""
    is_default_port = (protocol == "https" and port == "443") or (
        protocol == "http" and port == "80"
    )
    return f"{protocol}://{host}" if is_default_port else f"{protocol}://{host}:{port}"


def _load_agent_card() -> AgentCard:
    """Loads agent-card.json and patches in the two deploy-time-only
    fields (this service's own URL, and the DCR handler's URL) -- see
    module docstring for why a static file is used instead of ADK's own
    auto-built card."""
    raw = (Path(__file__).parent / "agent-card.json").read_text(encoding="utf-8")
    agent_url = _build_canonical_rpc_url(_a2a_protocol, _a2a_host, _a2a_port)
    raw = raw.replace("__AGENT_URL__", agent_url)
    raw = raw.replace("__DCR_TARGET_URL__", DCR_TARGET_URL)
    return AgentCard.model_validate(json.loads(raw))


a2a_app = to_a2a(
    root_agent,
    host=_a2a_host,
    port=int(_a2a_port),
    protocol=_a2a_protocol,
    agent_card=_load_agent_card(),
)

a2a_app.add_middleware(
    OAuth2AuthMiddleware,
    oidc_issuer=OIDC_ISSUER,
    jwks_uri=OIDC_JWKS_URI,
    audience=OAUTH_AUDIENCE,
)

if __name__ == "__main__":
    listen_port = int(os.environ.get("PORT", "8080"))
    uvicorn.run(a2a_app, host="0.0.0.0", port=listen_port)
