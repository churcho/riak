# D01 syn Metadata Evolution

Date: 2026-02-20
Status: Proposed for D01 rollout

## Current Baseline (v1)

Current coordinator metadata in syn registry/group:

- `dc`
- `node`
- `http_port`
- `riak_http`
- `riak_vsn`
- `started_at`

This shape is sufficient for discovery but not enough for policy-driven distribution and partial-failure contracts.

## D01 Metadata v2 (Backward-Compatible)

Additive fields:

- `syn_meta_vsn` (integer): metadata schema version (`2` for D01).
- `admin_api_vsn` (binary): Cowboy API contract version for compatibility gates.
- `capabilities` (map/list): supported distribution features
  - example keys: `remote_forward`, `aggregate_read`, `error_code_tags`.
- `health` (map): coarse health for routing
  - `state` (`healthy|degraded|down`),
  - `updated_at_ms`.
- `latency_budget_ms` (integer): advertised budget used for remote-forward policy selection.
- `forwarding` (map): explicit forward permissions and denylist state.

## Versioning Rules

1. Writers must always include legacy v1 keys.
2. Readers must treat unknown keys as optional.
3. If `syn_meta_vsn` is absent, treat entry as v1.
4. Routing features that require v2 fields must fail closed when metadata is missing.
5. Metadata changes are additive unless API version is explicitly bumped.

## Reader Strategy

Pseudo-contract for all metadata reads:

- Normalize to internal shape:
  - `meta_version = maps:get(syn_meta_vsn, Meta, 1)`
  - fill defaults for missing optional fields.
- Validate required legacy keys (`dc`, `node`, `http_port`).
- If required fields missing/corrupt, mark DC entry as `degraded` and exclude from forwarding target set.

## Conflict and Staleness Considerations

- Keep current oldest-process-wins registry conflict behavior.
- Add freshness guard using `health.updated_at_ms` and `started_at`.
- Distribution target selection must reject stale entries beyond configured TTL.

## Rollout Sequence

1. Deploy reader support for v1+v2 first (no writer changes).
2. Enable v2 writer fields in coordinator metadata publication.
3. Enable policy features that depend on v2 (`remote_forward`, advanced aggregate merge).
4. Observe mixed-version operation window; verify no v1 read regressions.
5. Enforce v2-only features after all production DCs advertise `syn_meta_vsn >= 2`.

## Rollback

- Disable v2-dependent features via kill switch.
- Keep v1 keys published; ignore v2-only fields.
- No downgrade migration required for syn state since readers remain backward-compatible.
