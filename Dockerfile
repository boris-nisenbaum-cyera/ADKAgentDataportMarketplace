# Container image for the Marketplace-packaged Cyera Dataport ADK/A2A
# agent -- see main.py's module docstring for how this differs from
# ../ADKAgentDataport (OAuth2/OIDC caller auth instead of Google Identity
# Platform, and a static Marketplace-shaped agent-card.json instead of an
# ADK-auto-built one).
#
# This agent has no Cyera credentials of its own baked in -- it only calls
# Cyera's already-hosted Dataport MCP gateway over HTTPS using
# CYERA_DATAPORT_MCP_TOKEN. Its A2A endpoint requires callers to present a
# valid OAuth 2.0 access token issued by oidc.cyera.io (see
# oauth_middleware.py) -- there is no shared-secret env var for that layer
# since it verifies real end-user identities via a third-party IdP.
#
#   docker build -t cyera-dataport-agent-marketplace .
#   docker run --rm -p 8080:8080 \
#       -e CYERA_DATAPORT_MCP_TOKEN="$CYERA_DATAPORT_MCP_TOKEN" \
#       -e GOOGLE_API_KEY="$GOOGLE_API_KEY" \
#       cyera-dataport-agent-marketplace
#
# On Cloud Run, set CYERA_DATAPORT_MCP_TOKEN from Secret Manager rather
# than a plain env var. $PORT is honoured automatically (Cloud Run sets
# it; main.py defaults to 8080 otherwise).

FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8080

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY agent.py __init__.py main.py oauth_middleware.py auth_context.py agent-card.json ./

EXPOSE 8080

CMD ["python", "main.py"]
