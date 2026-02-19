# Cowboy Compatibility Matrix (B00)

Date: 2026-02-19
Batch: B00
Branch: `feature/cowboy-b00-baseline-contracts`

This matrix captures HTTP compatibility requirements to preserve client behavior while migrating from Webmachine resources to Cowboy handlers.

## Alias coverage baseline

All applicable operations must normalize these legacy and modern aliases into one internal contract:

- Legacy: `/riak/...`
- Default-type modern: `/buckets/...`
- Typed modern: `/types/{bucket_type}/...`

## Behavior matrix

| Operation family | Alias routes in scope | Methods | Required status behavior | Required headers | Query semantics to preserve | Error mapping baseline | Source modules |
|---|---|---|---|---|---|---|---|
| Object read/write/delete | `/riak/{bucket}/{key}`, `/buckets/{bucket}/keys/{key}`, `/types/{bucket_type}/buckets/{bucket}/keys/{key}` | `GET`, `HEAD`, `PUT`, `POST`, `DELETE` | `200` read hit; `300` siblings; `404` miss; `201` create-path; `204` no-body write/delete; `503` quorum/timeout | `Content-Type`, `X-Riak-Vclock`, `ETag`, `Last-Modified`, `Link`, `X-Riak-Meta-*`, `X-Riak-Index-*`; `Location` on server-generated key | `r,w,dw,rw,pr,pw,node_confirms,basic_quorum,notfound_ok,asis,sync_on_write,timeout,vtag,returnbody` | `timeout -> 503`, quorum unsatisfied -> `503`, malformed rw params -> `400`, conflict precondition -> `412` | `riak_kv_wm_object`, `riak_kv_wm_utils` |
| Object create without key | `/riak/{bucket}` (`POST`), `/buckets/{bucket}/keys` (`POST`), `/types/{bucket_type}/buckets/{bucket}/keys` (`POST`) | `POST` | `201` with `Location`; `200` if `returnbody=true`; `204` otherwise | `Location`, `Content-Type`, `X-Riak-Vclock` (when body returned) | same as object write path | same as object write path | `riak_kv_wm_object` |
| Bucket listing | `/riak`, `/buckets`, `/types/{bucket_type}/buckets` | `GET`, `HEAD` | `200` always; expensive list only when requested | `Content-Type: application/json`; gzip/identity encoding support | `buckets=true|stream`, `timeout` | invalid timeout -> `400`; stream timeout payload includes `{"error":"timeout"}` | `riak_kv_wm_buckets` |
| Bucket props | `/riak/{bucket}?props=true`, `/buckets/{bucket}/props`, `/types/{bucket_type}/buckets/{bucket}/props` | `GET`, `HEAD`, `PUT`, `DELETE` (no `DELETE` on v1 alias) | `200` on GET; `204` on successful PUT/DELETE; `400` malformed JSON | `Content-Type: application/json` | PUT body must be `{"props":{...}}` | malformed body -> `400`; auth/security failure -> `403/426` | `riak_kv_wm_props`, `riak_kv_wm_utils` |
| Bucket-type props | `/types/{bucket_type}/props` | `GET`, `HEAD`, `PUT` | `200` GET; `204` PUT; `404` unknown type | `Content-Type: application/json` | PUT body must be `{"props":{...}}` | unknown type -> `404`; malformed body -> `400` | `riak_kv_wm_bucket_type` |
| Key listing (stream/non-stream) | `/riak/{bucket}?keys=true|stream`, `/buckets/{bucket}/keys`, `/types/{bucket_type}/buckets/{bucket}/keys` | `GET`, `HEAD` | `200` with JSON list; stream mode emits JSON chunks | `Content-Type: application/json`; gzip/identity | `keys=true|stream`, optional legacy `props=true`, `timeout` | invalid timeout -> `400`; stream timeout chunk includes `{"error":timeout}` | `riak_kv_wm_keylist` |
| Secondary index (2i) | `/buckets/{bucket}/index/{field}/{term_or_range}`, `/types/{bucket_type}/buckets/{bucket}/index/{field}/{term_or_range}` | `GET`, `HEAD` | `200` JSON results; stream mode `multipart/mixed`; `503` timeout | `Content-Type: application/json` or `multipart/mixed;boundary=...` | `max_results, stream=true, continuation, return_terms, pagination_sort, timeout, term_regex` | malformed query/params -> `400`; timeout -> `503` (non-stream) or stream error part | `riak_kv_wm_index` |
| MapReduce | `/mapred` | `POST` (plus `GET/HEAD` usage response) | `200` success; `400` request/phase validation; `500` execution/sink errors | `Content-Type: application/json`; with `chunked=true` return `multipart/mixed` | `chunked=true`, request JSON with `inputs` and `query` | invalid JSON/request -> `400`; pipeline errors/timeouts -> `500` | `riak_kv_wm_mapred` |
| Counter | `/buckets/{bucket}/counters/{key}` | `GET`, `POST` | `200` GET hit; `404` miss; `204` POST no return; `200` POST with `returnvalue`; `409` allow_mult false | `Content-Type: text/plain` | read quorums (`r,pr,basic_quorum,notfound_ok`), write quorums (`w,pw,dw,node_confirms`), `returnvalue` | malformed increment payload -> `400`; timeout/quorum -> `503` | `riak_kv_wm_counter` |
| CRDT datatype | `/types/{bucket_type}/buckets/{bucket}/datatypes`, `/types/{bucket_type}/buckets/{bucket}/datatypes/{key}` | `GET`, `HEAD`, `POST` | `200` GET hit; `404` miss; `201` create-path; `204` post success no body; optional `200` with `returnbody` | `Content-Type: application/json`; `Location` on generated key | read/write quorums, `include_context`, `returnbody`, `timeout` | default bucket type counter redirect -> `301`; malformed params/body -> `400/406`; timeout/quorum -> `503` | `riak_kv_wm_crdt` |

## Common compatibility guardrails

- Method filtering must preserve Webmachine `405` behavior and `Allow` header exposure where applicable.
- Security and CSRF-like referer/origin checks from `riak_kv_wm_utils:is_forbidden/*` remain part of compatibility surface.
- When a behavior is legacy-only (`link walking`, AAE fold/maintenance URLs), preserve documented status/error behavior if endpoint remains exposed, otherwise mark as explicitly deferred.

## Explicitly deferred in B00-B06 implementation batches

- Link walker multipart traversal (`riak_kv_wm_link_walker`)
- AAE fold/range/maintenance endpoints (`riak_kv_wm_aaefold`)
- Queue/membership maintenance endpoints (`riak_kv_wm_queue`)

These stay in the contract inventory and must be resolved during cutover planning before Webmachine retirement.
