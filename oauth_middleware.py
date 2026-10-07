"""Inbound authentication for this agent's A2A endpoint, via OAuth 2.0
Authorization Code Grant access tokens -- the auth model Google Cloud
Marketplace requires for an "Agent-as-a-Service" listing (see
https://github.com/ljogeiger/GE-A2A-Marketplace-Agent's README:
"To allow Gemini Enterprise to call your agent, you must support OAuth
2.0 Authorization Code Grant Flow").

THIS IS A DIFFERENT AUTH MODEL FROM ../ADKAgentDataport, DELIBERATELY
--------------------------------------------------------------------------
../ADKAgentDataport/auth_middleware.py gates access with a Google Identity
Platform ID token (or, for Gemini-Enterprise-Gateway/inter-agent calls, a
Cloud Run IAM-verified caller) -- both are Cyera-internal-GCP-project
concepts that only make sense for Cyera's OWN deployment of this agent.
A Marketplace listing is procured and used by OTHER organizations'
end users, who have no Cyera GCP identity at all -- they authenticate via
whatever OAuth 2.0 provider Cyera's own agent card advertises
(agent-card.json's securitySchemes.oauth2), and Gemini Enterprise obtains
a per-end-user access token via that flow before ever calling this agent.
This middleware verifies THAT token.

Confirmed live against Cyera's actual OIDC provider (not assumed) --
`curl https://oidc.cyera.io/.well-known/openid-configuration` returns a
real, standards-compliant discovery document with `jwks_uri:
"https://oidc.cyera.io/oidc/jwks"` and `issuer: "https://oidc.cyera.io"`.
This middleware verifies the inbound Bearer token's signature against
THAT jwks_uri and checks `iss`/`aud`/`exp` -- exactly the same shape as
../ADKAgentDataport's IdentityPlatformAuthMiddleware conceptually, just
against a third-party IdP's own JWKS instead of Google's Firebase certs.

WHAT THIS DOES NOT DO (BE AWARE)
--------------------------------------------------------------------------
- Does NOT implement the Authorization Code exchange itself -- that's
  Gemini Enterprise's own job (per the agent card's advertised
  authorizationUrl/tokenUrl), using whatever OAuth client credentials
  ../dcr/main.py issued during Dynamic Client Registration. This
  middleware only ever sees and verifies the resulting access token.
- Does NOT check OAuth scopes against specific tools/skills (e.g. per-tool
  scope enforcement like the reference repo's `agent:time` example) --
  every valid token accepted here has access to both of this agent's
  tools. Add scope-checking here first if that granularity is needed
  before this goes to production.
- The `aud` (audience) check is deliberately configurable
  (OAUTH_AUDIENCE env var) rather than hardcoded, since Marketplace
  partners commonly register a distinct audience per listing/environment
  -- confirm the real value with whoever owns oidc.cyera.io's client
  configuration before deploying.
"""
from __future__ import annotations

import logging
import os
import time
from typing import Any

import httpx
from jose import jwk, jwt
from jose.exceptions import JWTError
from jose.utils import base64url_decode
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

logger = logging.getLogger("cyera_dataport_agent_marketplace")

# The A2A protocol's own well-known discovery URI, plus the DCR endpoint
# extension path -- both must stay reachable without a Bearer token, same
# reasoning as ../ADKAgentDataport/auth_middleware.py's identical
# exemption (a calling agent/platform has to be able to discover how to
# authenticate before it can authenticate).
_PUBLIC_PATHS = frozenset({"/.well-known/agent-card.json"})

# Cache of {jwks_uri: (keys, monotonic_expiry)} -- avoids re-fetching the
# IdP's public keys on every single request. 1 hour matches this
# project's own established convention elsewhere (e.g.
# ../CyeraAnalyticsAgent/agent.py's _self_id_token_cache).
_JWKS_CACHE_TTL_SECONDS = 3600
_jwks_cache: dict[str, tuple[list[dict[str, Any]], float]] = {}


class OAuth2AuthMiddleware:
    """Starlette-style ASGI middleware: reject any HTTP request (other
    than the public Agent Card) that doesn't present a valid OAuth 2.0
    access token -- issued by `oidc_issuer` -- as a Bearer credential."""

    def __init__(
        self,
        app: ASGIApp,
        *,
        oidc_issuer: str,
        jwks_uri: str,
        audience: str | None = None,
    ) -> None:
        if not oidc_issuer:
            raise ValueError(
                "OAuth2AuthMiddleware requires a non-empty oidc_issuer "
                "(the OAuth2/OIDC provider's `iss` claim value, e.g. "
                "'https://oidc.cyera.io')."
            )
        if not jwks_uri:
            raise ValueError(
                "OAuth2AuthMiddleware requires a non-empty jwks_uri (the "
                "provider's public-key endpoint, e.g. "
                "'https://oidc.cyera.io/oidc/jwks')."
            )
        self.app = app
        self._oidc_issuer = oidc_issuer
        self._jwks_uri = jwks_uri
        self._audience = audience or None

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        if scope.get("path") in _PUBLIC_PATHS:
            await self.app(scope, receive, send)
            return

        headers = dict(scope.get("headers") or [])
        raw_auth = headers.get(b"authorization", b"").decode("utf-8", errors="replace")

        if not raw_auth.lower().startswith("bearer "):
            logger.warning("auth_reject reason=missing_or_malformed_bearer_header")
            await self._reject(
                scope, receive, send,
                "Missing 'Authorization: Bearer <OAuth2 access token>' header.",
            )
            return

        token = raw_auth[len("bearer "):].strip()
        if not token:
            logger.warning("auth_reject reason=empty_bearer_token")
            await self._reject(scope, receive, send, "Empty bearer token.")
            return

        try:
            claims = await self._verify_token(token)
        except Exception as exc:  # noqa: BLE001 -- ANY verification failure
            # must reject; this is a security gate, never fail open. The
            # detailed reason is logged server-side only -- the client
            # gets a generic message, not internals of why its token was
            # bad -- same convention as every other auth_middleware.py in
            # this project.
            logger.warning("auth_reject reason=%s", exc)
            await self._reject(scope, receive, send, "Invalid or expired access token.")
            return

        # Log only the token's subject (a stable, non-reversible user/
        # client ID), never other PII the token may carry -- consistent
        # with this whole project's logging conventions.
        logger.info("auth_accept sub=%s", claims.get("sub") or "<unknown>")
        await self.app(scope, receive, send)

    async def _verify_token(self, token: str) -> dict[str, Any]:
        """Verifies signature (via the IdP's own JWKS), `iss`, `exp`, and
        (if configured) `aud`. Raises on any failure."""
        unverified_header = jwt.get_unverified_header(token)
        kid = unverified_header.get("kid")
        if not kid:
            raise JWTError("Access token is missing 'kid' in its header.")

        signing_key = await self._get_signing_key(kid)
        if signing_key is None:
            raise JWTError(f"No matching signing key found for kid={kid!r}.")

        options = {"verify_aud": bool(self._audience)}
        claims = jwt.decode(
            token,
            signing_key,
            algorithms=[unverified_header.get("alg", "RS256")],
            audience=self._audience,
            options=options,
        )

        issuer = claims.get("iss")
        if issuer != self._oidc_issuer:
            raise JWTError(f"Unexpected issuer {issuer!r}, expected {self._oidc_issuer!r}.")

        return claims

    async def _get_signing_key(self, kid: str) -> dict[str, Any] | None:
        cached = _jwks_cache.get(self._jwks_uri)
        now = time.monotonic()
        if cached is None or cached[1] <= now:
            async with httpx.AsyncClient(timeout=10.0) as client:
                resp = await client.get(self._jwks_uri)
                resp.raise_for_status()
                keys = resp.json().get("keys", [])
            _jwks_cache[self._jwks_uri] = (keys, now + _JWKS_CACHE_TTL_SECONDS)
        else:
            keys = cached[0]

        for key in keys:
            if key.get("kid") == kid:
                return jwk.construct(key)

        # kid not found in the cached set -- the IdP may have rotated its
        # keys; force a fresh fetch once before giving up (mirrors
        # ../CyeraAnalyticsAgent/agent.py's own cache-then-retry pattern).
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.get(self._jwks_uri)
            resp.raise_for_status()
            keys = resp.json().get("keys", [])
        _jwks_cache[self._jwks_uri] = (keys, time.monotonic() + _JWKS_CACHE_TTL_SECONDS)
        for key in keys:
            if key.get("kid") == kid:
                return jwk.construct(key)
        return None

    @staticmethod
    async def _reject(scope: Scope, receive: Receive, send: Send, detail: str) -> None:
        response = JSONResponse({"error": "unauthorized", "detail": detail}, status_code=401)
        await response(scope, receive, send)
