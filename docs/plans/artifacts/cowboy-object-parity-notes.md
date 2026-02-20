# Cowboy Object CRUD Parity Notes (B02)

Date: 2026-02-19
Batch: B02
Branch: `feature/cowboy-b02-object-crud`

## Implemented in B02

- Replaced the B01 `501 not_implemented` substrate stub for object routes with operation dispatch in `riak_admin_api_handler`.
- Added object gateway operations in `riak_admin_api_riak:object_operation/3` for:
  - key-level `GET`, `HEAD`, `PUT`, `POST`, `DELETE`
  - collection `POST` create with server-generated key and `Location` header
- Added a raw response path (`riak_admin_api_response:raw_reply/5`) so object responses can preserve non-JSON body/content-type while still emitting compatibility headers and telemetry tags.

## Route and method coverage

The following normalized operations are now handled by Cowboy:

- `op=object_item`:
  - `/riak/:bucket/:key`
  - `/buckets/:bucket/keys/:key`
  - `/types/:type/buckets/:bucket/keys/:key`
  - methods: `GET`, `HEAD`, `PUT`, `POST`, `DELETE`
- `op=object_collection`:
  - `/riak/:bucket` (when normalized to collection create)
  - `/buckets/:bucket/keys`
  - `/types/:type/buckets/:bucket/keys`
  - method: `POST`

Non-object substrate operations remain deferred and continue to return explicit `501` in B02.

## Compatibility behavior implemented

- Status mapping and error mapping for common Riak object outcomes (`timeout`, quorum unsatisfied variants, precondition/conflict, not found, bucket type unknown).
- Compatibility headers on object replies via shared response helpers:
  - `X-Riak-Vclock`
  - `ETag`
  - `Last-Modified`
  - `Link`
- Metadata/index header passthrough for reads:
  - `X-Riak-Meta-*`
  - `X-Riak-Index-*`
- Conditional write path support:
  - `If-None-Match` -> conditional put option
  - `X-Riak-If-Not-Modified` -> conditional put option
  - conflict/precondition result mapping to `409`/`412`
- Sibling response forms:
  - default `text/plain` sibling list (`300`)
  - `multipart/mixed` sibling representation when requested via `Accept`
- Create-on-POST behavior for keyless POST:
  - server-generated key
  - `Location` header in response

## Test evidence (B02 additions)

- `apps/riak_admin_api/test/riak_admin_api_object_crud_test.erl`
  - object GET dispatch and compatibility headers
  - HEAD empty-body behavior
  - POST create + Location header
  - forwarding of conditional headers on write path
  - sibling response form handling
- `apps/riak_admin_api/test/riak_admin_api_riak_test.erl`
  - object error-map branch coverage
  - object option normalization helper coverage
  - location generation by alias family
- `apps/riak_admin_api/test/riak_admin_api_request_test.erl`
  - boolean query normalization extended for `asis`

## B02A route audit follow-up (2026-02-19)

- Added cross-check artifact:
  - `docs/plans/artifacts/cowboy-route-mapping-audit-b01-b02.md`
- Added route audit tests for:
  - alias equivalence across `/riak`, `/buckets`, and `/types`
  - malformed path-shape rejection (`//`) with `404 unknown_route`
  - method-not-allowed and `allow` header contract
  - translation from external path + method to normalized op and backend action
  - explicit verification that deferred non-object ops return `501 not_implemented`
- Tightened parser discipline in `riak_admin_api_request:normalize_path/3` so malformed double-slash paths are rejected before op normalization.

### B02A remaining risks

- Forward-looking parser branches for index routes remain ahead of Cowboy route declarations and are intentionally deferred to B04.
- B03/B04 must preserve current allowlist/error contract behavior while replacing deferred `501` branches with concrete handlers.

## Known deviations

- Historical B02 state: `If-Match` and `If-Unmodified-Since` were forwarded but not enforced. Current baseline (S2+) enforces these preconditions via gateway-side read-before-write checks.
- Link-header parsing for writes is intentionally conservative in this batch; read-side link emission is preserved, but full legacy write-time link validation/parsing parity remains for follow-up hardening.
