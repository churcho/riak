# S1 Resilience & Performance Hardening Notes

Date: 2026-02-20
Branch: `feature/cowboy-s1-resilience-perf`
Base: `feature/cowboy-client` at `f2ea468a`

## Scope

Five targeted S1 items drawn from the critical gaps register (CG-015 through CG-018, CG-005):

1. **Listener supervision + protocol limits** (CG-017)
2. **Blocking/latency hotspots** (CG-015, CG-016)
3. **Error semantics consistency** (CG-005, CG-018)
4. **Authn/authz hardening path**
5. **Observability enhancements**

## S1-001: Listener supervision + protocol limits (CG-017)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_app.erl`
- `apps/riak_admin_api/src/riak_admin_api_sup.erl`
- `apps/riak_admin_api/test/riak_admin_api_app_test.erl`

What changed:

- Cowboy listener is now started under the supervisor tree via `ranch:child_spec/5` instead of `cowboy:start_clear/3` outside the tree.
- `riak_admin_api_sup` changed from `start_link/0` to `start_link/1` accepting a listener child spec. Strategy changed from `one_for_one` to `rest_for_one`.
- Added `protocol_opts/0` with configurable limits:
  - `idle_timeout` (default 60000 ms)
  - `request_timeout` (default 30000 ms)
  - `max_keepalive` (default 100 requests/connection)
  - `max_header_name_length` (default 64 bytes)
  - `max_header_value_length` (default 4096 bytes)
  - `max_headers` (default 100)

Why safe:

- Listener crash now triggers automatic restart instead of silent unavailability.
- Protocol limits protect against resource exhaustion from slow/malicious clients.
- All limits are configurable via application env with safe defaults.

Verification:

- `listener_child_spec_returns_valid_child_spec_test` passes.
- `protocol_opts_returns_default_values_test` passes.
- `protocol_opts_respects_env_overrides_test` passes.

## S1-002: Blocking/latency hotspots (CG-015, CG-016)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_riak.erl`
- `apps/riak_admin_api/test/riak_admin_api_riak_test.erl`

What changed:

- **CG-015**: Replaced sequential `net_adm:ping/1` in `cluster_status/0` with `parallel_ping_nodes/2`. Each node is pinged in a separate spawned process. The caller waits at most `cluster_status_ping_timeout` ms (default 3000) for all responses. Nodes that don't respond are marked unreachable.
- **CG-016**: Added `stream_collection_ceiling/0` (default 300000 ms / 5 min) applied as `min(stream_timeout, ceiling)` in `collect_stream_buckets` and `collect_stream_keys`. If the ceiling fires, a warning is logged.

Why safe:

- Parallel pings bound total cluster_status latency to the configured timeout regardless of how many nodes are unreachable.
- Stream ceiling is a safety cap — it does not replace per-stream timeouts, only prevents unbounded blocking.
- Both values are configurable via application env.

Verification:

- `parallel_ping_nodes_empty_list_test` passes.
- `parallel_ping_nodes_unreachable_returns_false_test` passes.
- `parallel_ping_nodes_multiple_unreachable_test` passes.
- `stream_collection_ceiling_default_test` passes.
- `stream_collection_ceiling_override_test` passes.

## S1-003: Error semantics consistency (CG-005, CG-018)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_riak.erl`
- `apps/riak_admin_api/test/riak_admin_api_riak_test.erl`

What changed:

- **CG-005/CG-018**: MapReduce timeout errors now return `503 timeout` instead of `500 timeout` in both nonchunked and chunked paths. This is consistent with `query_operation` timeout mapping.
- **CG-005**: Added configurable `list_keys_error_mode/0`:
  - `compat` (default): returns `200` with embedded error JSON (backward-compatible).
  - `strict`: returns proper HTTP error status via `bucket_error_map/1`.

Why safe:

- MapReduce 503 change: clients already handling 500 timeouts should also handle 503. The status code now correctly signals a retryable condition.
- list_keys error mode defaults to `compat` for zero-disruption. Operators opt into `strict` explicitly.

Verification:

- `mapred_timeout_error_map_returns_503_test` passes.
- `list_keys_error_mode_default_compat_test` passes.
- `list_keys_error_mode_strict_test` passes.
- `list_keys_error_mode_invalid_falls_back_to_compat_test` passes.

## S1-004: Authn/authz hardening path

Scope:

- `apps/riak_admin_api/src/riak_admin_api_request.erl`
- `apps/riak_admin_api/src/riak_admin_api_handler.erl`
- `apps/riak_admin_api/test/riak_admin_api_request_test.erl`
- `apps/riak_admin_api/test/riak_admin_api_handler_test.erl`

What changed:

- Added `ensure_auth_guardrails/1` in the `ensure_security` chain.
- When `security_require_auth` is `true` (default: `false`) and no `authn_fun`/`authz_fun` is configured, requests are rejected with `503 auth_not_configured`.
- Handler `request_opts/1` now passes `require_auth` through from app env.

Why safe:

- Default is `false` — no change for existing deployments.
- Prevents accidental unprotected operation in production deployments where auth is mandatory.
- Logs an error when triggered for operator visibility.

Verification:

- `auth_guardrail_disabled_by_default_test` passes.
- `auth_guardrail_true_no_hooks_returns_503_test` passes.
- `auth_guardrail_true_authn_only_returns_503_test` passes.
- `auth_guardrail_true_authz_only_returns_503_test` passes.
- `auth_guardrail_true_both_hooks_passes_test` passes.
- `auth_guardrail_respects_app_env_test` passes.
- `handler_init_with_require_auth_blocks_without_hooks_test` passes.
- `handler_init_with_require_auth_and_hooks_passes_through_test` passes.

## S1-005: Observability enhancements

Scope:

- `apps/riak_admin_api/src/riak_admin_api_response.erl` (verified, no changes needed)

What changed:

- Verified that existing `error_code` telemetry tag dimension (added in D01) already propagates consistently across all error paths, including the new S1 error paths:
  - `auth_not_configured` (S1-004) flows through `reply_error_map` which already includes error_code.
  - `mapred_timeout_error_map` (S1-003) uses the standard `{error, Map}` return which flows through `with_error_context`.

Why safe:

- No code changes required — existing telemetry pipeline is sufficient.

## Compatibility Notes

- **MapReduce timeout status change (500 → 503)**: This is a breaking change for clients that specifically match on `500` for mapred timeouts. However, `503` is the correct HTTP semantics for a retryable timeout condition, and `query_operation` already uses `503`. Clients should be handling `5xx` as a class.
- **All other changes are backward-compatible** with default configuration.

## Configuration Reference

| Key | Default | Description |
|---|---|---|
| `cowboy_idle_timeout` | 60000 | Keep-alive idle timeout (ms) |
| `cowboy_request_timeout` | 30000 | Request receive timeout (ms) |
| `cowboy_max_keepalive` | 100 | Max requests per connection |
| `cowboy_max_header_name_length` | 64 | Max header name (bytes) |
| `cowboy_max_header_value_length` | 4096 | Max header value (bytes) |
| `cowboy_max_headers` | 100 | Max headers per request |
| `cluster_status_ping_timeout` | 3000 | Parallel ping timeout (ms) |
| `stream_collection_ceiling_ms` | 300000 | Stream collection ceiling (ms) |
| `list_keys_error_mode` | `compat` | `compat` or `strict` |
| `security_require_auth` | `false` | Require auth hooks configured |
