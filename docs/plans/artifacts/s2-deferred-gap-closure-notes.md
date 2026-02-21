# S2 Deferred Gap Closure Notes

Date: 2026-02-20
Branch: `feature/cowboy-s2-streaming-conditions-parity`
Base: `feature/cowboy-client` at `26b17f1f`

## Scope

Five deferred gaps from the critical gaps register (CG-001, CG-004, CG-006, CG-007, CG-008):

1. **True incremental streaming/backpressure** (CG-001)
2. **Conditional-write enforcement completeness** (CG-004)
3. **MapReduce backend availability control** (CG-006)
4. **CRDT redirect parity scope** (CG-007)
5. **/riak counters alias decision** (CG-008)

## S2-001: True incremental streaming (CG-001)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_riak.erl`
- `apps/riak_admin_api/src/riak_admin_api_handler.erl`
- `apps/riak_admin_api/src/riak_admin_api_response.erl`
- `apps/riak_admin_api/test/riak_admin_api_riak_test.erl`
- `apps/riak_admin_api/test/riak_admin_api_handler_test.erl`

What changed:

- **Response module**: Added `stream_reply_init/4` (wraps `cowboy_req:stream_reply/3`) and `stream_reply_body/3` (wraps `cowboy_req:stream_body/3`) for chunked HTTP response streaming.
- **Handler module**: Added `{stream, StreamInit, ChunkFun}` pattern in `execute_bucket_backend/6`. New `reply_stream/5` function creates an `Emit` callback that delegates to `stream_reply_body/3`, invokes the gateway's `ChunkFun`, and catches/logs stream errors.
- **Gateway module**: Modified `stream_buckets_reply/3`, `stream_keys_reply/5`, `stream_index_reply/2`, and `mapred_collect_chunked_reply/2` to branch on `stream_incremental_enabled/0`:
  - When `true` (default): returns `{stream, StreamInit, ChunkFun}` tuple. ChunkFun receives an `Emit` callback and sends JSON chunks incrementally via Cowboy's chunked transfer encoding.
  - When `false`: preserves existing aggregated-body compatibility behavior.
- Added incremental streaming functions:
  - `stream_buckets_chunked/3` + `stream_buckets_chunked_loop/3`
  - `stream_keys_chunked/3` + `stream_keys_chunked_loop/3`
  - `stream_index_chunked/9`
  - `mapred_stream_chunked_parts/4`
- Added `stream_incremental_enabled/0` config function (app env `stream_incremental_enabled`, default `true`).

Why safe:

- Toggle-controlled: `stream_incremental_enabled` defaults to `true` for new behavior; operators can set `false` to revert to aggregated-body mode.
- Stream ceiling (S1) still applies: all chunked loops respect `stream_collection_ceiling/0`.
- JSON output structure is preserved: `{"buckets":[...]}`, `{"keys":[...]}` etc.
- Handler catches stream errors gracefully, logging and sending error chunk before `fin`.

Verification:

- `stream_incremental_enabled_default_true_test` passes.
- `stream_incremental_enabled_override_false_test` passes.
- `handler_stream_dispatch_sends_chunked_response_test` passes.

## S2-002: Conditional-write enforcement (CG-004)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_riak.erl`
- `apps/riak_admin_api/test/riak_admin_api_riak_test.erl`

What changed:

- **`conditional_put_options/1`**: Now extracts `If-Match` and `If-Unmodified-Since` headers from the request and includes them as `{if_match, Value}` and `{if_unmodified_since, Value}` in the options list. `If-None-Match` is validated via `if_none_match_option/1` — only `*` is accepted; entity-tag values return `400 invalid_if_none_match` (D01 hardening).
- **`object_store/4`**: Calls `check_write_preconditions/3` before the actual `riak_client:put/3` call. If preconditions fail, returns `{error, #{status => 412, ...}}`.
- **`check_write_preconditions/3`**: HTTP-layer conditional enforcement via read-before-write pattern:
  1. Scans options for `if_match` and `if_unmodified_since`.
  2. If neither present, returns `ok` immediately (no overhead).
  3. If present, does `riak_client:get/4` to read current object.
  4. For `If-Match`: compares ETag (stripped of quotes) against object vtags.
  5. For `If-Unmodified-Since`: parses HTTP date and compares against object's last-modified timestamp.
  6. Returns `ok` or `{error, #{status => 412}}`.
- **`filter_riak_cond_opts/1`**: Strips HTTP-layer conditionals (`if_match`, `if_unmodified_since`) from options before passing to `riak_client:put`, since Riak KV doesn't understand these.
- Added helpers: `strip_etag_quotes/1`, `check_if_match/3`, `check_if_unmodified_since/2`, `parse_http_date/1`, `lastmod_to_seconds/1`.

Why safe:

- Read-before-write pattern correctly implements HTTP conditional semantics that Riak KV lacks natively.
- When no conditional headers are present, the hot path is a single options scan — no additional read.
- Riak's native `if_none_match` and `if_not_modified` continue to be forwarded to `riak_client:put`. The `if_none_match` value is now validated at the HTTP layer (only `*` accepted) before reaching Riak.
- `filter_riak_cond_opts/1` prevents passing unknown options to Riak.

Verification:

- `check_write_preconditions_no_conditions_passes_test` passes.
- `check_write_preconditions_if_match_no_object_fails_test` passes.
- `check_write_preconditions_if_unmodified_since_no_object_fails_test` passes.

## S2-003: MapReduce backend availability control (CG-006)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_riak.erl`
- `apps/riak_admin_api/test/riak_admin_api_riak_test.erl`

What changed:

- Added `mapred_backend_enabled/0` config function (app env `mapred_backend_enabled`, default `true`).
- Modified `mapred_operation/3` to check `mapred_backend_enabled()` first:
  - When `false` (operator-disabled): returns `{error, #{status => 503, code => <<"service_unavailable">>}}`.
  - When `true`: falls through to existing `mapred_backend_available()` which checks module presence and returns 501 if absent.
- Added `mapred_disabled_error/0` returning the 503 error map.

Why safe:

- Two-level availability: operator toggle (503) is separate from build capability (501). This gives clear error semantics:
  - `503 service_unavailable`: operator chose to disable MapReduce.
  - `501 not_implemented`: MapReduce modules are absent from the build.
- Default is `true` — no change for existing deployments.
- Operator toggle is immediately effective without restart (app env read on each request).

Verification:

- `mapred_backend_enabled_default_true_test` passes.
- `mapred_backend_enabled_override_false_test` passes.

## S2-004: CRDT collection redirect parity (CG-007)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_riak.erl`
- `apps/riak_admin_api/test/riak_admin_api_riak_test.erl`

What changed:

- Added `maybe_crdt_collection_redirect/1` function: when `bucket_type` is `<<"default">>` and `key` is `undefined` or `<<>>` (collection/create path), returns `{redirect, <<"/buckets/.../counters">>}`.
- Modified `crdt_update_operation/2` (now with `crdt_update_operation_inner/4`) to check `maybe_crdt_collection_redirect/1` for `create` mode after the keyed redirect check. This ensures that POST-to-create on the CRDT collection path with default bucket type gets the same 301 redirect as keyed paths.

Why safe:

- Redirect only fires for `default` bucket type with no key — the same condition as the keyed redirect, just for the collection path.
- Non-default bucket types are unaffected.
- `crdt_update_operation_inner/4` preserves all existing behavior for non-redirect cases.

Verification:

- `crdt_collection_redirect_default_type_no_key_test` passes.
- `crdt_collection_redirect_default_type_empty_key_test` passes.
- `crdt_collection_redirect_non_default_type_no_redirect_test` passes.
- `crdt_collection_redirect_default_with_key_no_redirect_test` passes.

## S2-005: /riak counters alias decision (CG-008)

Scope:

- `apps/riak_admin_api/test/riak_admin_api_request_test.erl` (test evidence only)

What changed:

- **Decision: explicit rejection (no alias).** The `/riak` normalizer (`normalize_riak/3`) only recognizes 0/1/2-segment paths (`/riak`, `/riak/Bucket`, `/riak/Bucket/Key`). Any longer path shape including `/riak/Bucket/counters/Key` falls through to the catch-all which returns `{error, #{status => 404, code => <<"unknown_route">>}}`.
- No code changes were needed — the catch-all correctly rejects the path.
- Added test evidence confirming the behavior.

Why safe:

- No `/riak/.../counters/...` route ever existed in the Cowboy migration. The webmachine-era `riak_kv_wm_counter` resource was separate from the admin API.
- Clients using the legacy counter path should use `/buckets/Bucket/counters/Key` which is fully supported.
- The 404 response includes an explicit `unknown_route` error code for diagnostics.

Verification:

- `riak_counters_path_returns_404_test` passes.
- `riak_counters_collection_path_returns_404_test` passes.

## Compatibility Notes

- **CG-001 streaming mode change**: Defaults to incremental streaming. Clients receiving chunked transfer-encoded responses must handle progressive JSON delivery. Toggle `stream_incremental_enabled => false` to revert.
- **CG-004 conditional writes**: `If-Match` and `If-Unmodified-Since` now enforced with 412 responses. Previously these headers were forwarded but not checked. `If-None-Match` now only accepts `*`; entity-tag values (e.g., `"etag-1"`) return 400 `invalid_if_none_match`. Previously any value was silently treated as `{if_none_match, true}`.
- **CG-006 mapred toggle**: New `mapred_backend_enabled` config (default `true`). When set `false`, mapred returns 503 instead of proceeding.
- **CG-007 CRDT create redirect**: Default bucket-type CRDT create (POST, no key) now returns 301 to `/buckets/.../counters`. Previously proceeded without redirect.
- **CG-008**: No behavioral change — `/riak/.../counters/...` was always 404.

## Configuration Reference

| Key | Default | Description |
|---|---|---|
| `stream_incremental_enabled` | `true` | Enable chunked streaming for key/bucket/index/mapred |
| `mapred_backend_enabled` | `true` | Operator toggle for MapReduce backend |
