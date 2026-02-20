# S5 Quality & Consistency Pass Notes

Date: 2026-02-20
Branch: `feature/cowboy-s5-quality-consistency`
Base: `feature/cowboy-client` at `c96fd528`

## Scope

Six medium/low items drawn from the quality backlog:

1. **CORS response headers** (M-4)
2. **Stream error framing consistency** (M-7)
3. **Body-size enforcement consistency** (M-6)
4. **Conversion helper duplication** (M-2)
5. **JSON library consistency plan** (M-1)
6. **L-level cleanup**

## S5-001: CORS response headers (M-4)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_response.erl`
- `apps/riak_admin_api/src/riak_admin_api_handler.erl`
- `apps/riak_admin_api/test/riak_admin_api_response_test.erl`
- `apps/riak_admin_api/test/riak_admin_api_handler_test.erl`

What changed:

- Added `cors_headers/2` to the response module. When `trusted_origins` is configured and the request `Origin` matches, the function emits:
  - `Access-Control-Allow-Origin` (echoing the matched origin)
  - `Access-Control-Allow-Methods` (GET, HEAD, PUT, POST, DELETE, OPTIONS)
  - `Access-Control-Allow-Headers` (Content-Type, X-Request-Id, X-Riak-Vclock, etc.)
  - `Access-Control-Expose-Headers` (X-Request-Id, X-Riak-Vclock, ETag, etc.)
  - `Access-Control-Max-Age` (3600 seconds)
- `compat_headers/1` now merges CORS headers when applicable.
- Handler `response_opts/2` passes `request_origin` from the request headers.
- Handler `init/2` threads `trusted_origins` from request opts into reply opts.

Why safe:

- When `trusted_origins` is empty (the default), no CORS headers are emitted. Zero behavior change for existing deployments.
- CORS headers are purely additive response metadata. They do not alter origin validation, auth checks, or any other security pipeline behavior.
- Only matched origins get `Access-Control-Allow-Origin`; mismatched origins get nothing.

Verification:

- `cors_headers_match_emits_headers_test` passes.
- `cors_headers_mismatch_emits_nothing_test` passes.
- `cors_headers_no_trusted_origins_emits_nothing_test` passes.
- `cors_headers_no_origin_emits_nothing_test` passes.
- `cors_headers_merged_into_compat_headers_test` passes.
- `cors_headers_emitted_when_origin_matches_test` passes (handler integration).
- `cors_headers_not_emitted_when_no_trusted_origins_test` passes (handler integration).
- `cors_headers_not_emitted_when_origin_mismatch_test` passes (handler integration).

## S5-002: Stream error framing consistency (M-7)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_riak.erl`
- `apps/riak_admin_api/test/riak_admin_api_riak_test.erl`

What changed:

- Introduced `encode_stream_error/1` as the single stream error JSON encoder. All stream error paths now delegate to it:
  - `encode_bucket_stream_timeout/0` (was: inline `mochijson2:encode`)
  - `encode_key_stream_timeout/0` (was: inline `mochijson2:encode`)
  - `encode_key_stream_error/1` (was: inline `mochijson2:encode`)
  - `encode_index_error/1` (was: separate function with same logic)
  - MapReduce chunked stream errors (was: `jsx:encode` with map format)
- The unified encoder uses `mochijson2:encode({struct, [{error, Reason}]})` for atoms/binaries and formats complex terms through `io_lib:format("~p", [Reason])`.

Why safe:

- Bucket/key stream errors: output is byte-identical (already used mochijson2 `{error, Reason}` shape).
- Index stream errors: output is byte-identical (was already `{error, Reason}` shape via separate `encode_index_error`).
- MapReduce stream errors: **wire-format change** from `{"error":"timeout","reason":"mapreduce timed out"}` (jsx map) to `{"error":"timeout"}` (mochijson2 struct). This is a simplification that aligns with the established stream error framing. Clients parsing the `error` field are unaffected; clients parsing the `reason` field within stream error chunks will see it absent. This is acceptable because the error code is the meaningful signal, and the surrounding multipart boundary already identifies the response as an error.

Verification:

- `encode_stream_error_atom_test` passes.
- `encode_stream_error_binary_test` passes.
- `encode_stream_error_tuple_test` passes.

## S5-003: Body-size enforcement consistency (M-6)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_handler.erl`
- `apps/riak_admin_api/test/riak_admin_api_handler_test.erl`

What changed:

- `read_request_body/1` now enforces `max_request_body_bytes` on the `#{body := Body}` fast path. Previously, when a body was pre-populated in the request map (used by tests and potentially by middleware), the size check was bypassed entirely.
- Binary bodies: checked with `byte_size(Body) > MaxBody`.
- Iolist bodies: converted to binary first, then checked.
- Undefined bodies: still return `{ok, <<>>, Req}` (no size to check).

Why safe:

- The chunked Cowboy read path is unchanged.
- The only behavior change is that pre-populated bodies exceeding the limit now return `{error, body_too_large, Req}` instead of silently passing through. This is strictly more correct.
- Test bodies within the limit are unaffected.

Verification:

- `body_size_limit_enforced_on_preread_body_test` passes.
- `body_size_limit_allows_preread_body_within_limit_test` passes.

## S5-004: Conversion helper duplication (M-2)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_response.erl`
- `apps/riak_admin_api/src/riak_admin_api_request.erl`
- `apps/riak_admin_api/src/riak_admin_api_riak.erl` (documentation only)
- `apps/riak_admin_api/test/riak_admin_api_response_test.erl`

What changed:

- `riak_admin_api_response:to_binary/1` is now exported as the canonical shared conversion helper. Added `-spec to_binary(term()) -> binary()`.
- `riak_admin_api_request:to_binary/1` now delegates to `riak_admin_api_response:to_binary/1` instead of reimplementing the same 5 clauses.
- `riak_admin_api_riak:to_bin/1` retains its local implementation (60+ call sites) with a documentation note pointing to the canonical version. A full rename to `to_binary` would be a high-churn change with no behavioral benefit.

Why safe:

- All three implementations were byte-identical. The request module now calls the response module's version, producing identical results.
- The riak gateway module is unchanged at runtime — only a doc comment was added.
- No call sites were modified, only the backing implementation in the request module.

Verification:

- `to_binary_binary_test` passes.
- `to_binary_atom_test` passes.
- `to_binary_integer_test` passes.
- `to_binary_list_test` passes.
- `to_binary_fallback_test` passes.
- All existing tests in request and response modules continue to pass.

## S5-005: JSON library consistency plan (M-1)

No code changes. Documentation only.

### Approved JSON encoding/decoding paths

| Context | Library | Rationale |
|---|---|---|
| HTTP response bodies (json_reply, error_reply) | jsx | Modern maps-based encoding; already the default in response module |
| Bucket props encode/decode (get/set) | mochijson2 | Required for `{struct, [...]}` format compatibility with riak_kv_wm_props |
| Bucket/key list stream chunks | mochijson2 | Established wire format; matches legacy client expectations |
| Index stream results/errors | mochijson2 | Multipart boundary framing expects mochijson2 output |
| MapReduce stream results | mochijson2 | Phase/data encoding uses mochijson2 `{struct, [...]}` |
| MapReduce stream errors | mochijson2 | S5 (M-7) unified to match other stream error paths |
| Query/MapReduce POST body decode | jsx (handler) / mochijson2 (gateway) | Handler decodes JSON object; gateway decodes mochijson2 for Riak input |
| Admin API responses (/api/*) | jsx | All rah_* handlers use json_reply → jsx |

### Migration strategy (deferred)

Full mochijson2-to-jsx migration is deferred. The dual-library approach is acceptable because:

1. mochijson2 is only used in `riak_admin_api_riak.erl` (the gateway) where it interfaces with riak_kv legacy types.
2. jsx is used at the HTTP boundary (response module, handler JSON decode).
3. The two libraries never produce conflicting output for the same data path.
4. A full migration would require changing ~30 encode call sites in the gateway, touching bucket props wire format, and verifying backward compatibility across all stream modes.

Future work: if riak_kv drops mochijson2 dependency, this module should follow.

## S5-006: L-level cleanup

- Added documentation comments to `to_bin/1` in the riak gateway noting the relationship to the canonical `to_binary/1`.
- Consolidated `encode_index_error` from a 3-clause function to a 2-clause delegator through `encode_stream_error/1`.

No behavioral changes. No large rewrites.

## Compatibility Notes

- **MapReduce stream error shape change**: Stream error chunks in mapred chunked responses now emit `{"error":"timeout"}` instead of `{"error":"timeout","reason":"mapreduce timed out"}`. The `error` field value is preserved. Clients that parsed only the `error` field are unaffected. Clients that relied on the `reason` field within stream error chunks will see it absent. This is a minor wire-format change within the multipart stream body.
- **All other changes are backward-compatible** with default configuration.

## Configuration Reference

No new configuration keys introduced. CORS headers piggyback on the existing `security_trusted_origins` configuration from S0.

| Key | Default | S5 behavior |
|---|---|---|
| `security_trusted_origins` | `[]` | When non-empty and request Origin matches, CORS response headers are emitted |
| `max_request_body_bytes` | 5242880 | Now enforced on pre-populated body paths too |
