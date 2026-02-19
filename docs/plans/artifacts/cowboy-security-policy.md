# Cowboy Security Policy Baseline (B01)

Date: 2026-02-19
Batch: B01
Branch: `feature/cowboy-b01-http-substrate`

## Scope

This policy defines the B01 security envelope enforced by the shared request substrate (`riak_admin_api_request`) and response serializer (`riak_admin_api_response`).

It covers transport checks, origin filtering, authentication/authorization hooks, and request correlation.

## Enforcement points

Security runs in this order during request normalization:

1. TLS gate (`require_tls`)
2. Origin gate (`trusted_origins` for unsafe methods)
3. Authentication hook (`authn_fun`)
4. Authorization hook (`authz_fun`)

Any failure returns the standard error envelope from `cowboy-error-taxonomy.md`.

## Policy controls

### 1) Request ID propagation (always on)

- Header source: `x-request-id`
- If absent: generate monotonic ID (`riak-admin-<n>`)
- Response always emits `x-request-id`

This is mandatory for auditability and cross-node tracing.

### 2) TLS requirement (configurable)

- Toggle: `security_require_tls`
- Input signal: `x-forwarded-proto`
- If enabled and proto is not `https`: return `426 tls_required`

Default in B01: disabled (for parity-friendly rollout).

### 3) Origin allowlist (configurable)

- Control: `security_trusted_origins = [<<"https://...">>, ...]`
- Applied only to unsafe methods (`POST`, `PUT`, `DELETE`, etc.)
- Missing origin is tolerated; present-but-untrusted origin returns `403 forbidden`

This mirrors Webmachine-era origin/referer hardening intent while keeping rollout low risk.

### 4) Authn/Authz hooks (pluggable)

Request substrate accepts `authn_fun` and `authz_fun`.

Supported returns:

- `ok | allow`
- `unauthorized`
- `forbidden`
- `{deny, Status, Code, Reason}`
- `{error, ErrorMap}`

Unsupported returns trigger `500 security_hook_error`.

## Route-level behavior

`/riak`, `/buckets`, and `/types` alias families are wired through the shared handler and security envelope.

In B01 these routes intentionally return `501 not_implemented` after normalization/security success; B02 replaces this stub with operation dispatch.

## Operational guidance

- Keep `security_require_tls=false` during early migration testing unless ingress already guarantees TLS headers.
- Introduce `authn_fun`/`authz_fun` in staging first and confirm taxonomy mappings before production enablement.
- Preserve `x-request-id` in logs and external gateway traces.
