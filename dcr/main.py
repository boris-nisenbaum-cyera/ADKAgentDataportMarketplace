"""Marketplace procurement + Dynamic Client Registration handler for the
Cyera Dataport agent listing -- adapted from
https://github.com/ljogeiger/GE-A2A-Marketplace-Agent's
5_gcp_marketplace_setup/marketplace_handler.py.

Deployed as its OWN, separate Cloud Run service from ../main.py's agent
(see ../README.md and the top-level deploy.ps1/deploy.sh) -- this is
Google Cloud Marketplace/Procurement-facing infrastructure, not part of
the A2A agent's own runtime request path.

Single hybrid endpoint, branching on request shape (identical structure
to the reference repo's own handler):
  - Body has "software_statement": Gemini Enterprise's synchronous DCR
    call. Validate the JWT (see dcr/utils.py's validate_jwt(), which
    checks it against Google's own real public keys), look up the
    Marketplace order's already-registered OAuth client in Firestore, and
    return it. 400s if the order isn't registered yet (i.e. the
    Pub/Sub-driven procurement flow below hasn't run for it).
  - Otherwise: a Pub/Sub push message. Only "ACCOUNT_CREATION_REQUESTED"
    events are handled -- approve the order via Google's real Procurement
    API, register a new OAuth client against Cyera's own OIDC provider
    (dcr/utils.py's register_oidc_client(), NOT the reference repo's
    Okta-specific call), and persist the {order_id -> client_id,
    client_secret} mapping to Firestore for the synchronous path above to
    find later.

NOT YET TESTED END-TO-END (see ../README.md): this requires a real
Marketplace listing/order to exist to exercise for real. See that file
for exactly what still needs Cyera's own action before this can go live.
"""
from __future__ import annotations

import base64
import json
import logging
import os

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from google.auth.transport.requests import AuthorizedSession
from google.auth import default as google_auth_default

from utils import (
    find_client_by_order_id,
    register_oidc_client,
    save_client_mapping,
    validate_jwt,
)

logger = logging.getLogger("cyera_dataport_dcr")
app = FastAPI()

# Cyera's own OIDC provider's real, live-confirmed RFC 7591 registration
# endpoint -- see dcr/utils.py's module docstring for how this was
# confirmed (its own /.well-known/openid-configuration document).
OIDC_REGISTRATION_ENDPOINT = os.environ.get(
    "OIDC_REGISTRATION_ENDPOINT", "https://oidc.cyera.io/oidc/reg"
)

# This service's own public URL, used as the OAuth redirect_uri Gemini
# Enterprise's authorization-code callback lands on. Set by deploy.ps1/
# deploy.sh after this service's first Cloud Run deploy (same two-phase
# pattern as ../main.py's A2A_HOST for the agent service itself).
GEMINI_ENTERPRISE_REDIRECT_URI = os.environ.get("GEMINI_ENTERPRISE_REDIRECT_URI", "")

PROCUREMENT_API_BASE = "https://cloudcommerceprocurement.googleapis.com/v1"


async def _approve_order(resource_name: str) -> None:
    """Approves a Marketplace order via Google's real Procurement API,
    using this service's own ambient Cloud Run service-account
    credentials (google.auth.default()) -- same call shape as the
    reference repo's procurement-api.sh manual equivalent, done here
    programmatically as part of the Pub/Sub event handler."""
    credentials, _ = google_auth_default(
        scopes=["https://www.googleapis.com/auth/cloud-platform"]
    )
    session = AuthorizedSession(credentials)
    resp = session.post(f"{PROCUREMENT_API_BASE}/{resource_name}:approve", json={})
    resp.raise_for_status()


def _extract_order_id(payload: dict) -> str | None:
    """Marketplace Pub/Sub payload shapes vary by event source (Producer
    Portal vs. Procurement API push) -- check the known possible
    locations, same defensive shape as the reference repo's own handler."""
    for path in (
        ("account", "id"),
        ("order", "id"),
        ("providerEvent", "order", "id"),
    ):
        node = payload
        for key in path:
            if not isinstance(node, dict) or key not in node:
                node = None
                break
            node = node[key]
        if isinstance(node, str) and node:
            return node
    return None


@app.post("/dcr")
async def dcr_or_procurement_event(request: Request) -> JSONResponse:
    body = await request.json()

    software_statement = body.get("software_statement")
    if software_statement:
        try:
            claims = validate_jwt(software_statement)
        except Exception as exc:  # noqa: BLE001 -- security gate, never fail open
            logger.warning("dcr_reject reason=%s", exc)
            return JSONResponse({"error": "invalid_software_statement"}, status_code=400)

        order_id = claims.get("google.order")
        if not order_id:
            return JSONResponse({"error": "missing_order_claim"}, status_code=400)

        existing = find_client_by_order_id(order_id)
        if existing is None:
            logger.warning("dcr_reject reason=order_not_yet_provisioned order_id=%s", order_id)
            return JSONResponse({"error": "order_not_provisioned"}, status_code=400)

        return JSONResponse(
            {
                "client_id": existing["client_id"],
                "client_secret": existing["client_secret"],
                "client_secret_expires_at": 0,
            }
        )

    # Otherwise: a Pub/Sub push message envelope.
    message = body.get("message") or {}
    data_b64 = message.get("data")
    if not data_b64:
        return JSONResponse({"error": "unrecognized_request"}, status_code=400)

    try:
        payload = json.loads(base64.b64decode(data_b64).decode("utf-8"))
    except Exception as exc:  # noqa: BLE001
        logger.warning("pubsub_decode_failed reason=%s", exc)
        return JSONResponse({"error": "bad_pubsub_payload"}, status_code=400)

    event_type = payload.get("eventType")
    if event_type != "ACCOUNT_CREATION_REQUESTED":
        # Ack (200) any other event type so Pub/Sub doesn't keep retrying
        # delivery for events this handler intentionally doesn't act on.
        logger.info("pubsub_ignored event_type=%s", event_type)
        return JSONResponse({"status": "ignored"})

    order_id = _extract_order_id(payload)
    if not order_id:
        logger.warning("pubsub_missing_order_id payload_keys=%s", list(payload.keys()))
        return JSONResponse({"error": "missing_order_id"}, status_code=400)

    resource_name = payload.get("name") or payload.get("providerEvent", {}).get("name")
    if resource_name:
        await _approve_order(resource_name)

    registration = await register_oidc_client(
        registration_endpoint=OIDC_REGISTRATION_ENDPOINT,
        redirect_uris=[GEMINI_ENTERPRISE_REDIRECT_URI] if GEMINI_ENTERPRISE_REDIRECT_URI else [],
        client_name=f"gemini-enterprise-order-{order_id}",
    )
    save_client_mapping(order_id, registration["client_id"], registration["client_secret"])
    logger.info("order_provisioned order_id=%s", order_id)
    return JSONResponse({"status": "provisioned"})


@app.get("/healthz")
async def healthz() -> JSONResponse:
    return JSONResponse({"status": "ok"})


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8081")))
