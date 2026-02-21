# Cowboy Error Taxonomy (B01)

Date: 2026-02-19
Batch: B01
Branch: `feature/cowboy-b01-http-substrate`

## Standard error envelope

All substrate failures return one JSON shape:

```json
{
  "status": 400,
  "error": "invalid_query",
  "reason": "Boolean query params must be true|false",
  "request_id": "riak-admin-12345"
}
```

Response headers always include:

- `content-type: application/json; charset=utf-8`
- `x-request-id: <request_id>`

## Taxonomy

| HTTP status | Error code | Trigger | Notes |
|---|---|---|---|
| `400` | `invalid_if_none_match` | `If-None-Match` header contains entity-tag value instead of `*` | Raised by `riak_admin_api_riak:if_none_match_option/1` (D01) |
| `400` | `invalid_query` | Query coercion failure (`boolean`, `quorum`, `timeout`) | Raised by `riak_admin_api_request:normalize_query/1` |
| `401` | `unauthorized` | Authn hook denies request | Hook contract in security policy |
| `403` | `forbidden` | Authz hook denies request; origin policy failure | Security envelope response |
| `404` | `unknown_route` | Path not in `/riak`, `/buckets`, `/types` substrate matrix | Alias normalization guardrail |
| `405` | `method_not_allowed` | Method outside operation allowlist | `allow` header is emitted |
| `426` | `tls_required` | `security_require_tls=true` and non-HTTPS transport | Uses `x-forwarded-proto` check |
| `500` | `backend_error` | Generic handler/backend failure | Existing admin handlers preserve this |
| `500` | `json_encoding_error` | Response JSON encoding crash | Serializer fallback path |
| `500` | `security_hook_error` | Invalid hook config or unsupported hook return | Policy/setup issue |
| `501` | `not_implemented` | Substrate route wired before B02 data-path logic | Intentional B01 stub behavior |

## Compatibility behavior

- `method_not_allowed` keeps Webmachine-style signaling through `allow`.
- Response serializer supports compatibility headers (`x-riak-vclock`, `etag`, `last-modified`, `link`) so B02+ handlers can attach them without custom code.
- Error payload is stable across all alias families (`/riak`, `/buckets`, `/types`).
