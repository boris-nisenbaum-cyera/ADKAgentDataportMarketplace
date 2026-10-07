# Container image for the Marketplace procurement + Dynamic Client
# Registration handler -- see main.py's module docstring. Deployed as its
# own, separate Cloud Run service from ../ (the A2A agent itself).
#
#   docker build -t cyera-dataport-dcr .
#   docker run --rm -p 8081:8081 cyera-dataport-dcr
#
# Requires GOOGLE_CLOUD_PROJECT's ambient credentials (Cloud Run's own
# attached service account) for both the Procurement API :approve call and
# Firestore access -- no static credentials are baked into this image.

FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8081

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py utils.py ./

EXPOSE 8081

CMD ["python", "main.py"]
