"""Dynamic Client Registration (DCR) helpers for the Marketplace
procurement handler (see main.py) -- adapted from
https://github.com/ljogeiger/GE-A2A-Marketplace-Agent's
5_gcp_marketplace_setup/dcr/utils.py, with its Okta-specific
register_okta_client() replaced by register_oidc_client(), a generic
RFC 7591 call against Cyera's own OIDC provider.

WHY oidc.cyera.io INSTEAD OF AN OKTA-SPECIFIC ADMIN API
--------------------------------------------------------------------------
The reference repo's own IdP choice (Okta) has no standard RFC 7591
`registration_endpoint` in its discovery document, so its utils.py talks
to Okta's proprietary Apps Management API instead. Cyera's own OIDC
provider is different -- confirmed live
(`curl https://oidc.cyera.io/.well-known/openid-configuration`) to
advertise a real `registration_endpoint`
("https://oidc.cyera.io/oidc/reg"), i.e. it already speaks standard
RFC 7591 Dynamic Client Registration. So register_oidc_client() below is
a generic, spec-compliant POST to that endpoint -- no Cyera- or
Okta-specific admin API glue needed. This has NOT been tested end-to-end
against a real oidc.cyera.io registration (see this directory's own
README.md "What still requires your own action" section) -- whoever
administers that IdP needs to confirm /oidc/reg is actually permitted for
this external use case before this goes live.
"""
from __future__ import annotations

import logging
import os
import time
from typing import Any

import httpx
from google.auth.transport import requests as google_requests
from google.oauth2 import id_token
from google.cloud import firestore

logger = logging.getLogger("cyera_dataport_dcr")

# Google's own real, published public keys for the Marketplace DCR JWT
# signer -- confirmed to be the exact URL used by the reference repo's own
# README/code, not guessed. The `iss` on these tokens is this same
# service account.
GOOGLE_DCR_CERT_URL = (
    "https://www.googleapis.com/service_accounts/v1/metadata/x509/"
    "cloud-agentspace@system.gserviceaccount.com"
)
GOOGLE_DCR_ISSUER = "cloud-agentspace@system.gserviceaccount.com"

# This service's own advertised base URL -- the `aud` a valid Marketplace
# DCR software_statement JWT must carry (Google signs the JWT with THIS
# value as audience, taken from the Agent Card's own DCR extension
# target_url at the time Gemini Enterprise fetched it). Must match exactly
# what main.py serves at /dcr, including scheme/host.
PROVIDER_URL = os.environ.get("DCR_PROVIDER_URL", "")

_FIRESTORE_COLLECTION = "marketplace_clients"
_firestore_client: firestore.Client | None = None


def _get_firestore_client() -> firestore.Client:
    global _firestore_client
    if _firestore_client is None:
        _firestore_client = firestore.Client()
    return _firestore_client


def validate_jwt(software_statement: str) -> dict[str, Any]:
    """Verifies a Marketplace DCR `software_statement` JWT against
    Google's own real public keys, and checks `iss`/`exp`/`aud`. Raises on
    any failure -- same "never fail open on a security gate" convention as
    ../oauth_middleware.py."""
    request = google_requests.Request()
    claims = id_token.verify_token(
        software_statement,
        request,
        audience=PROVIDER_URL or None,
        certs_url=GOOGLE_DCR_CERT_URL,
    )
    if claims.get("iss") != GOOGLE_DCR_ISSUER:
        raise ValueError(f"Unexpected DCR JWT issuer {claims.get('iss')!r}.")
    return claims


def find_client_by_order_id(order_id: str) -> dict[str, Any] | None:
    doc = _get_firestore_client().collection(_FIRESTORE_COLLECTION).document(order_id).get()
    return doc.to_dict() if doc.exists else None


def save_client_mapping(order_id: str, client_id: str, client_secret: str) -> None:
    _get_firestore_client().collection(_FIRESTORE_COLLECTION).document(order_id).set(
        {
            "order_id": order_id,
            "client_id": client_id,
            "client_secret": client_secret,
            "created_at": time.time(),
        }
    )


async def register_oidc_client(
    *,
    registration_endpoint: str,
    redirect_uris: list[str],
    client_name: str,
) -> dict[str, Any]:
    """Generic RFC 7591 Dynamic Client Registration against Cyera's own
    OIDC provider -- replaces the reference repo's Okta-specific
    register_okta_client(). Returns the provider's registration response
    (expected to include at least `client_id` and `client_secret`)."""
    payload = {
        "client_name": client_name,
        "redirect_uris": redirect_uris,
        "grant_types": ["authorization_code", "refresh_token"],
        "response_types": ["code"],
        "token_endpoint_auth_method": "client_secret_post",
        "scope": "openid profile email offline_access",
    }
    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await client.post(registration_endpoint, json=payload)
        resp.raise_for_status()
        return resp.json()
