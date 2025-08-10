# NinjaMagic Zig Prototype

This repo contains a small multiplayer MUD server written in Zig. It combines an HTTP front‑end, a WebSocket protocol, and a collection of in‑server systems that update the world on a fixed tick.

## Structure
- `src/main.zig` – program entry; spawns HTTP & WS servers and drives the tick loop.
- `src/state.zig` – global state and tick coordinator.
- `src/core/` – shared types and utilities (configuration, signal bus, world helpers).
- `src/sys/` – gameplay systems (parse input, move actors, emit text, etc.).
- `src/net/` – web and websocket front‑ends.
- `embed/` – static assets embedded into the binary.
- `pytest/` – end‑to‑end WebSocket tests.

## Getting Started
```sh
zig build run   # start server
zig build test  # run tests
```
The HTTP server serves a simple terminal client that connects via WebSocket.

## Next Steps
- Extend `sys/parse.zig` with new verbs.
- Implement placeholder systems (look, attack, health).
- Explore templating in `core/zts.zig` and database code under `src/db*`.
