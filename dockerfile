# ──────────── build stage ─────────────
FROM alpine:latest AS build
RUN apk add --no-cache curl xz tar
# Install zig.
## zzz is locked to 0.14.0 atm
RUN curl -sSL https://ziglang.org/download/0.14.0/zig-linux-x86_64-0.14.0.tar.xz | tar -xJ --strip-components=1 -C /usr/local/bin
RUN zig version
# Install sqlc.
RUN curl -sSL https://downloads.sqlc.dev/sqlc_1.29.0_linux_arm64.tar.gz | tar -xz -C /usr/local/bin sqlc
WORKDIR /repo/
COPY . .
RUN --mount=type=cache,target=/root/.cache zig build -Dtarget=aarch64-linux-musl;

# ──────────── deploy + runtime ────────
FROM alpine:latest AS runtime
RUN apk add --no-cache openssl ca-certificates
COPY --from=build /repo/zig-out/bin/mud /usr/local/bin/mud

EXPOSE 9862 9224
ENTRYPOINT ["/usr/local/bin/mud"]

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
