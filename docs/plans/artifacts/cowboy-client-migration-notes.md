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

Set in runtime config for targeted cutover/rollback (safe baseline keeps default disabled and enables only intended operation groups):

```erlang
{riak_admin_api, [
  {cowboy_cutover_default_mode, disabled},
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

---

## S2 Behavior Changes Addendum

Date: 2026-02-20
Branch: `feature/cowboy-s2-streaming-conditions-parity`

### Client-Visible Changes

| Change | Impact | Default | Migration action |
|---|---|---|---|
| Incremental streaming for key/bucket/index/mapred responses | Responses now use chunked transfer encoding instead of buffered bodies | Enabled (`stream_incremental_enabled = true`) | Ensure HTTP client handles chunked transfer-encoding. Set `stream_incremental_enabled = false` to revert to buffered mode. |
| If-Match / If-Unmodified-Since enforcement | PUT/POST requests with these headers now receive 412 Precondition Failed when conditions aren't met | Always active when headers present | Previously these headers were accepted but not enforced. Clients relying on unconditional writes despite sending conditional headers may see new 412 responses. Remove conditional headers to restore unconditional behavior. |
| MapReduce operator toggle | MapReduce returns 503 Service Unavailable when operator disables it | Enabled (`mapred_backend_enabled = true`) | No client action unless operator disables mapred. Handle 503 separately from 501 (backend absent). |
| CRDT collection create redirect | POST to create CRDT on default bucket type now returns 301 redirect to `/buckets/.../counters` | Always active for default bucket type | Follow 301 redirect to legacy counter URL. |
| /riak counters alias | `/riak/Bucket/counters/Key` returns 404 | N/A (always 404) | Use `/buckets/Bucket/counters/Key` instead. |

### New Configuration Keys

| Key | Default | Description |
|---|---|---|
| `stream_incremental_enabled` | `true` | Enable chunked streaming for key/bucket/index/mapred |
| `mapred_backend_enabled` | `true` | Operator toggle for MapReduce backend |

### Chunked Transfer Encoding Notes

When `stream_incremental_enabled` is `true` (default), the following endpoints return chunked transfer-encoded responses:

- `GET /buckets` (bucket listing)
- `GET /buckets/:bucket/keys` (key listing)
- `GET /buckets/:bucket/index/:field/:term` and range queries (2i)
- `POST /mapred` with `?chunked=true` (MapReduce chunked mode)

The JSON payload structure is preserved (e.g., `{"keys":["k1","k2",...]}`) but may arrive in multiple TCP segments. Clients must accumulate chunks before JSON parsing if they require complete payloads.
