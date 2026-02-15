# riak_admin_api

A Cowboy-based REST API for Riak cluster administration.

## Background

Riak's existing HTTP interface is built on Webmachine/Mochiweb and serves the data-path API (bucket/key CRUD operations) on port 10018 (configurable). The admin API is a new OTP application that runs Cowboy on a dedicated port (default **8099**) to provide cluster management endpoints. The long-term goal is to migrate all of Riak's HTTP handling from Webmachine to Cowboy; this application is the first step in that transition.

### Why a new HTTP server?

Riak's existing Webmachine/Mochiweb stack is aging and the long-term goal is to replace it entirely with Cowboy. The admin API is the first step in that migration. During the transition, both servers run side by side so that:

- **Incremental migration** — New endpoints are built on Cowboy from the start; existing Webmachine endpoints continue to work unchanged.
- **Traffic isolation** — Admin operations (cluster joins, status queries, configuration changes) cannot starve data-path read/write operations.
- **Security boundary** — Operators can apply different firewall rules to the admin port (e.g., restrict to internal/management networks).
- **Modern stack** — Cowboy 2.x provides a well-maintained HTTP/1.1 and HTTP/2 stack with clean routing semantics, native WebSocket support, and active upstream development.

## Architecture

```
riak_admin_api (OTP application)
├── riak_admin_api_app    — Application callback; starts Cowboy listener
├── riak_admin_api_sup    — Top-level supervisor (empty for now)
└── handlers/
    └── rah_ping          — GET /api/ping health-check handler
```

### Handler naming

All handler modules use the `rah_` prefix (**R**iak **A**dmin **H**andler) to keep dispatch rules concise and avoid name collisions with Riak's existing modules.

### Dependencies

| Dependency | Version | Purpose |
|-----------|---------|---------|
| cowboy | 2.12.0 | HTTP server |
| jsx | 3.1.0 | JSON encoding/decoding |

These are declared in both `apps/riak_admin_api/rebar.config` and the top-level `rebar.config`. Keep versions in sync.

## Endpoints

### GET /api/ping

Health check. Returns the node name and status.

```bash
$ curl -s http://127.0.0.1:8099/api/ping | python3 -m json.tool
{
    "node": "dev1@127.0.0.1",
    "status": "ok"
}
```

## Configuration

The admin API port defaults to **8099** and is set in the application environment:

```erlang
%% In riak_admin_api.app.src
{env, [
    {http_port, 8099}
]}
```

To override in a release, add to `etc/advanced.config`:

```erlang
[
    {riak_admin_api, [
        {http_port, 9099}
    ]}
].
```

## Port map (devrel)

In a devrel cluster, each node uses the Riak HTTP port assigned by `gen_dev`. The admin API currently uses a single fixed port (8099), so only one node serves the admin API in local development. Future milestones will assign per-node admin ports.

| Service | Port | Notes |
|---------|------|-------|
| Riak HTTP (dev1) | 10018 | Data-path API (Webmachine) |
| Riak PB (dev1) | 10017 | Protocol Buffers |
| Admin API | 8099 | This application (Cowboy) |

## macOS Apple Silicon note

See the [macOS code-signing](#macos-apple-silicon-code-signing) section in the top-level README for important information about running devrel builds on Apple Silicon Macs.
