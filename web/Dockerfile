FROM --platform=$BUILDPLATFORM node:22-alpine AS frontend
WORKDIR /build
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY frontend/ ./
RUN npm run build

FROM python:3.13-slim AS runtime
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    WEB_DATA_DIR=/data \
    WEB_STATIC_DIR=/app/static
WORKDIR /app
COPY backend/ /app/backend/
RUN python -m pip install --no-cache-dir /app/backend \
    && groupadd -g 10001 synonote \
    && useradd -u 10001 -g synonote -r -s /usr/sbin/nologin synonote \
    && mkdir -p /data /app/static \
    && chown synonote:synonote /data \
    && chmod 700 /data
COPY --from=frontend /build/dist /app/static
USER synonote
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/api/ready', timeout=3)" || exit 1
CMD ["uvicorn", "synonote_web.main:create_app", "--factory", "--host", "0.0.0.0", "--port", "8080", "--no-proxy-headers", "--workers", "1", "--no-access-log"]
