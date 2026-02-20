# S0 Security Hardening Notes

Date: 2026-02-20
Branch: `feature/cowboy-s0-security-hardening`
Base: `feature/cowboy-client` at `5ff1e72e`
Status: S0 pass complete

## Remediations Implemented

### S0-001: Unsafe `binary_to_term` (CRITICAL → Closed)

Scope:
- `apps/riak_admin_api/src/riak_admin_api_riak.erl` (line 482)

What changed:
- Replaced `binary_to_term(Body)` with `binary_to_term(Body, [safe])` in the `accept_doc_value/2` function for `application/x-erlang-binary` content type.

Why this matters:
- Without `[safe]`, a malicious client can craft an Erlang external term format payload containing novel atoms, exhausting the VM's atom table and crashing the node.
- With `[safe]`, `binary_to_term` refuses to create atoms that don't already exist, preventing atom table exhaustion attacks.

Tests added:
- `accept_doc_value_safe_term_decode_test` — valid term decodes correctly.
- `accept_doc_value_corrupted_binary_returns_raw_body_test` — corrupted binary falls back to raw body.
- `accept_doc_value_rejects_atom_creation_payload_test` — crafted ETF payload with unknown atom is rejected by `[safe]`, falls back to raw body.
- `accept_doc_value_non_erlang_passthrough_test` — non-erlang content types pass through unchanged.

### S0-002: TLS header spoofing and proxy trust (HIGH → Closed)

Scope:
- `apps/riak_admin_api/src/riak_admin_api_request.erl` (`ensure_tls/2`)
- `apps/riak_admin_api/src/riak_admin_api_handler.erl` (`request_opts/1`)

What changed:
- `ensure_tls/2` no longer trusts `X-Forwarded-Proto` header by default.
- New config key: `security_trust_proxy_headers` (default: `false`).
- When `require_tls => true` and `trust_proxy_headers => false`, the TLS check fails closed — there is no trustworthy TLS signal.
- When `trust_proxy_headers => true`, the existing `X-Forwarded-Proto` logic applies.
- `request_opts/1` now reads `security_trust_proxy_headers` from application env and passes it through as `trust_proxy_headers`.

Why this matters:
- Previously, any client could send `X-Forwarded-Proto: https` to bypass the TLS requirement.
- Operators must now explicitly opt in to proxy header trust when running behind a TLS-terminating reverse proxy.

Tests added:
- `tls_required_without_proxy_trust_rejects_spoofed_header_test` — spoofed header rejected when proxy trust disabled.
- `tls_required_with_proxy_trust_accepts_https_header_test` — header accepted when proxy trust enabled.
- `tls_required_with_proxy_trust_rejects_http_header_test` — http header rejected even with proxy trust.
- `tls_not_required_allows_any_request_test` — no TLS requirement means all pass.

### S0-003: Request body size limits (HIGH → Closed)

Scope:
- `apps/riak_admin_api/src/riak_admin_api_handler.erl` (`read_request_body`, `read_request_body_chunks`, `with_request_body`)

What changed:
- `read_request_body_chunks/4` now tracks accumulated body size and throws `body_too_large` when the limit is exceeded.
- Configurable via `max_request_body_bytes` application env (default: 5 MiB).
- `with_request_body/3` catches `body_too_large` and returns HTTP 413 `payload_too_large` with a clear error message.

Why this matters:
- Previously, a malicious client could send an unbounded request body, exhausting the Cowboy handler process's memory and potentially the entire VM.

Tests added:
- `body_size_limit_rejects_oversized_body_test` — verifies limit enforcement.
- `body_size_limit_allows_within_limit_body_test` — verifies normal bodies pass through.

### S0-004: Substrate routes disabled by default (HIGH → Closed)

Scope:
- `apps/riak_admin_api/src/riak_admin_api.app.src`

What changed:
- `cowboy_cutover_default_mode` changed from `enabled` to `disabled`.
- Substrate/data-path routes (`/riak/...`, `/buckets/...`, `/types/...`, `/mapred`) are now blocked with 503 by default.
- Admin routes (`/api/...`) are unaffected — they use separate `rah_*` handlers that don't go through cutover control.
- Operators must explicitly set `cowboy_cutover_default_mode => enabled` or configure per-op modes to expose substrate endpoints.

Why this matters:
- Previously, the admin port exposed full data-path CRUD, MapReduce, and CRDT operations with no authentication by default — a complete backdoor.
- Now, operators must make a deliberate choice to enable these endpoints.

Tests added:
- `substrate_disabled_by_default_blocks_data_path_test` — object_item blocked with disabled default.
- `substrate_explicit_enable_overrides_disabled_default_test` — per-op enable works.
- `substrate_mapred_blocked_by_default_disabled_test` — mapred blocked with disabled default.

### S0-005: Origin policy hardening for unsafe methods (MEDIUM → Closed)

Scope:
- `apps/riak_admin_api/src/riak_admin_api_request.erl` (`ensure_origin/2`)

What changed:
- When `trusted_origins` is configured and the HTTP method is unsafe (POST, PUT, DELETE), a missing `Origin` header now results in a 403 Forbidden.
- Previously, missing Origin was unconditionally allowed, allowing non-browser clients to bypass origin checks entirely.
- Safe methods (GET, HEAD, OPTIONS) continue to be allowed without Origin.
- When `trusted_origins` is empty (unconfigured), no origin check is performed.

Tests added:
- `origin_missing_on_unsafe_method_denied_when_origins_configured_test`
- `origin_present_and_trusted_on_unsafe_method_allowed_test`
- `origin_present_but_untrusted_on_unsafe_method_denied_test`
- `origin_missing_on_safe_method_allowed_when_origins_configured_test`
- `origin_not_checked_when_trusted_origins_empty_test`

### S0-006: Compile-time isolation documentation correction (CRITICAL → Closed)

Scope:
- `apps/riak_admin_api/src/riak_admin_api_riak.erl` (module docs)
- `apps/riak_admin_api/src/riak_admin_api.app.src` (isolation principle docs)

What changed:
- Corrected the module documentation to accurately state that this gateway module has compile-time dependencies on riak_kv headers via `-include_lib`.
- Removed the false claim that `rebar3 compile` works without Riak source present.
- Documented the specific headers depended upon and their purpose.
- Added a "future work" note for replacing include_lib deps with locally defined records/macros.
- Updated `.app.src` isolation principle docs to match.

Why this matters:
- The previous documentation claimed full compile-time isolation, which was false and could mislead anyone attempting to extract the app to a standalone repo.

## Deferred Items (documented, not deeply refactored)

### SD-001: `net_adm:ping` sequential latency
- `cluster_status/0` calls `net_adm:ping/1` sequentially for all members.
- Unreachable nodes cause multi-second blocking per node.
- Mitigation: consider async pings with timeout or cached reachability.

### SD-002: Stream collection blocking in handler process
- `collect_stream_buckets/keys/index` use blocking `receive` in Cowboy handler.
- A few slow streams can exhaust handler processes.
- Mitigation: spawn collection in separate process with backpressure.

### SD-003: Listener supervision architecture
- Cowboy listener started outside supervision tree in `start/2`.
- If listener crashes, admin API becomes silently unavailable.
- Mitigation: use `cowboy:child_spec/3` under supervisor.

### SD-004: MapReduce/query timeout contract unification
- Query timeout returns 503; mapred timeout returns 500.
- Inconsistent client contract.
- Mitigation: unify to 503 or explicitly document intentional divergence.

## New Configuration Keys

| Key | Default | Description |
|-----|---------|-------------|
| `security_trust_proxy_headers` | `false` | Trust `X-Forwarded-Proto` header for TLS detection. Enable only when behind a trusted TLS-terminating reverse proxy. |
| `max_request_body_bytes` | `5242880` (5 MiB) | Maximum request body size in bytes. Requests exceeding this limit receive 413 Payload Too Large. |
| `cowboy_cutover_default_mode` | `disabled` (changed from `enabled`) | Default cutover mode for substrate routes. Must be explicitly set to `enabled` to expose data-path endpoints. |
