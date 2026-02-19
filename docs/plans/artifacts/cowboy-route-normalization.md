# Cowboy Route Normalization Spec (B00)

Date: 2026-02-19
Batch: B00
Branch: `feature/cowboy-b00-baseline-contracts`

## Objective

Define one canonical internal request contract that accepts the three external path families:

- `/riak/...` (legacy)
- `/buckets/...` (default-type modern)
- `/types/{bucket_type}/...` (typed modern)

All Cowboy handlers in B01+ must consume this normalized shape, not raw alias-specific paths.

## Canonical request model

```erlang
#{
  op := op_id(),
  bucket_type := binary(),          %% defaults to <<"default">>
  bucket := binary() | undefined,
  key := binary() | undefined,
  field := binary() | undefined,    %% 2i field
  range := {binary(), binary()} | undefined,
  extras := map(),                  %% route-specific tokens
  query := map(),                   %% normalized query params
  alias := riak | buckets | types,  %% incoming route family
  api_version := 1 | 2 | 3
}.
```

## Path alias normalization

| Incoming pattern | Canonical internal shape |
|---|---|
| `/riak/{bucket}/{key}` | `bucket_type=<<"default">>`, `op=object_item` |
| `/buckets/{bucket}/keys/{key}` | `bucket_type=<<"default">>`, `op=object_item` |
| `/types/{type}/buckets/{bucket}/keys/{key}` | `bucket_type={type}`, `op=object_item` |
| `/riak/{bucket}` with `props=true` | `bucket_type=<<"default">>`, `op=bucket_props` |
| `/buckets/{bucket}/props` | `bucket_type=<<"default">>`, `op=bucket_props` |
| `/types/{type}/buckets/{bucket}/props` | `bucket_type={type}`, `op=bucket_props` |
| `/riak` | `bucket_type=<<"default">>`, `op=buckets` |
| `/buckets` | `bucket_type=<<"default">>`, `op=buckets` |
| `/types/{type}/buckets` | `bucket_type={type}`, `op=buckets` |

## Operation IDs

- `ping`
- `stats`
- `mapred`
- `buckets`
- `bucket_props`
- `bucket_type_props`
- `keys`
- `object_collection` (POST create with server-generated key)
- `object_item`
- `index_query`
- `counter_item`
- `crdt_collection`
- `crdt_item`
- `link_walk` (deferred)
- `aae_ops` (deferred)
- `queue_ops` (deferred)

## Query normalization rules

### Booleans

Normalize case-insensitive `"true"|"false"`; reject other values with `400`.

Keys using boolean parsing include:

- `basic_quorum`
- `notfound_ok`
- `returnbody`
- `returnvalue`
- `include_context`
- `stream`
- `return_terms`
- `pagination_sort`

### Quorum values

Normalize quorum params to `default | one | quorum | all | integer()`:

- `r`, `pr`, `w`, `pw`, `dw`, `rw`, `node_confirms`

Invalid value => `400` with text error payload for compatibility.

### Stream modes

- Bucket listing: `buckets=stream`
- Key listing: `keys=stream`
- 2i: `stream=true`
- MapReduce: `chunked=true`

Normalized representation:

```erlang
query.stream_mode := none | buckets | keys | index | mapred
```

### Timeout

- Parse `timeout` as integer milliseconds.
- Endpoint-specific compatibility exceptions are preserved (for example CRDT `timeout=0` as infinity).

## URI decoding and header compatibility

- Percent-decoding follows legacy behavior from `riak_kv_wm_utils:maybe_decode_uri/2`.
- Respect `X-Riak-URL-Encoding: on` compatibility switch where applicable.
- Preserve legacy response header contracts at serializer stage:
  - `X-Riak-Vclock`, `ETag`, `Last-Modified`, `Link`
  - `X-Riak-Meta-*`, `X-Riak-Index-*`

## Conflict resolution order for ambiguous legacy `/riak/{bucket}`

For legacy alias only, route resolver order is:

1. `keys=true|stream` => `op=keys`
2. `props!=false` and not keys mode => `op=bucket_props`
3. `POST` => `op=object_collection`
4. fallback => `op=bucket_props` (legacy-compatible default behavior)

This matches the original dispatch guard intent (`is_keylist/1`, `is_props/1`, `is_post/1`).

## Deferred route policy

For `link_walk`, `aae_ops`, and `queue_ops` in B00-B06:

- keep parser entries and operation IDs reserved,
- return explicit `501 not_implemented` only when feature flags keep them disabled,
- maintain inventory and compatibility notes for B08 cutover decisions.
