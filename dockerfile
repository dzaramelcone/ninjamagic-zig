# ──────────── latency sidecar ─────────
FROM alpine:latest AS slow
RUN apk add --no-cache iproute2 bash
COPY tools/apply_netem.sh /apply_netem.sh
ENTRYPOINT ["/apply_netem.sh"]

# ──────────── integration client ──────
FROM python:alpine3.22 AS pytest
WORKDIR repo
COPY pytest/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY ./pytest ./pytest