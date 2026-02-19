# Cowboy Client Migration Notes (B08)

Date: 2026-02-19  
Batch: B08  
Audience: operators, SDK maintainers, direct HTTP clients

## Summary

Cowboy is the active HTTP substrate for the migrated endpoint families. B08 introduces explicit operation-level cutover controls and finalizes the deprecation schedule for legacy route aliases.

## What Does Not Change

- Normalized operation semantics and backend actions from B02-B07 remain unchanged.
- Alias families `/riak`, `/buckets`, and `/types` still normalize to the same canonical operations.
- Request-id propagation (`x-request-id`) remains required on all responses.

## Client-Visible Route Status

| Route family | Status as of 2026-02-19 | Deprecation starts | Planned removal date |
|---|---|---|---|
| `/buckets/...` | Supported (primary) | N/A | None planned |
| `/types/...` | Supported (primary) | N/A | None planned |
| `/riak/...` | Supported (legacy alias) | 2026-03-10 | 2026-09-30 |
| `/mapred` | Supported (legacy singleton path) | 2026-03-10 | 2026-09-30 |

Interpretation:

- `Supported`: fully available and covered by contract tests.
- `Deprecated`: still available, but clients should migrate off before removal date.
- `Removed`: endpoint group may be set to `removed` mode, returning `410 route_removed`.

## Migration Guidance by Client Type

- Direct HTTP clients using `/riak/...`:
  - migrate to `/buckets/...` or `/types/...` equivalents.
  - stop relying on ambiguous `/riak/:bucket` query-shape behavior where possible.
- Query/mapred clients:
  - keep payload contracts unchanged.
  - validate fallback behavior for `503 route_cutover_disabled` and `410 route_removed`.
- CRDT/counter clients:
  - no request-body schema changes in B08.
  - ensure retry logic handles explicit cutover rollback responses.

## Operator Configuration Example

Set in runtime config for targeted cutover/rollback:

```erlang
{riak_admin_api, [
  {cowboy_cutover_default_mode, enabled},
  {cowboy_cutover_op_modes, [
    {mapred, deprecated},
    {object_item, enabled},
    {object_collection, enabled},
    {keys, enabled},
    {index_query, enabled},
    {counter, enabled},
    {crdt_item, enabled},
    {crdt_collection, enabled}
  ]}
]}.
```

## Operational Checklist

1. Run contract harness and EUnit before changing cutover modes.
2. Apply mode changes by endpoint group, not globally.
3. Monitor `route`, `op`, `alias`, `status`, `duration_us`, and `request_id`.
4. If rollback criteria trigger, follow `docs/plans/artifacts/cowboy-rollback-runbook.md`.

## Deferred Topics

- Multi-DC distribution/routing behavior changes are not part of B08 and remain tracked in D01.
