# Cowboy Endpoint Inventory (B00)

Date: 2026-02-19
Batch: B00
Branch: `feature/cowboy-b00-baseline-contracts`

## Source baseline

This inventory is derived from `riak_kv_web:dispatch_table/0` and related `riak_kv_wm_*` modules.

- Local branch `openriak-3.4` in this repo does not currently contain `riak_kv_web.erl` and `riak_kv_wm_*` source files under the paths listed in the batch doc.
- For B00 contract capture, route/behavior source was taken from the canonical upstream modules:
  - `https://raw.githubusercontent.com/basho/riak_kv/develop/src/riak_kv_web.erl`
  - `https://raw.githubusercontent.com/basho/riak_kv/develop/src/riak_kv_wm_object.erl`
  - `https://raw.githubusercontent.com/basho/riak_kv/develop/src/riak_kv_wm_utils.erl`
  - plus referenced `riak_kv_wm_*` modules for endpoint-specific behavior.

## Classification keys

- `core_required`: must exist for compatibility cutover.
- `required_streaming`: required endpoint where stream semantics are part of compatibility.
- `deferred_legacy`: retain contract reference, but not in immediate migration batches.

## Dispatch inventory (deduplicated)

| Route template | Legacy module | Class | Target Cowboy module | Batch | Notes |
|---|---|---|---|---|---|
| `/ping` | `riak_kv_wm_ping` | core_required | `rah_ping` | B01 | Health baseline endpoint.
| `/stats` | `riak_kv_wm_stats` | core_required | `rah_stats` | B01 | Operational stats surface.
| `/mapred` | `riak_kv_wm_mapred` | core_required | `rah_mapred` | B05 | Supports `chunked=true` streaming mode.
| `/riak` | `riak_kv_wm_buckets` | core_required | `rah_buckets` | B03 | Legacy bucket listing alias.
| `/buckets` | `riak_kv_wm_buckets` | core_required | `rah_buckets` | B03 | Default-type bucket listing.
| `/types/{bucket_type}/buckets` | `riak_kv_wm_buckets` | core_required | `rah_buckets` | B03 | Typed bucket listing.
| `/riak/{bucket}` with `props=true` | `riak_kv_wm_props` | core_required | `rah_bucket_props` | B03 | Legacy props access.
| `/buckets/{bucket}/props` | `riak_kv_wm_props` | core_required | `rah_bucket_props` | B03 | Default bucket props.
| `/types/{bucket_type}/buckets/{bucket}/props` | `riak_kv_wm_props` | core_required | `rah_bucket_props` | B03 | Typed bucket props.
| `/types/{bucket_type}/props` | `riak_kv_wm_bucket_type` | core_required | `rah_bucket_type` | B03 | Bucket type props.
| `/riak/{bucket}` with `keys=true|stream` | `riak_kv_wm_keylist` | required_streaming | `rah_keys` | B04 | Legacy key listing mode.
| `/buckets/{bucket}/keys` | `riak_kv_wm_keylist` | required_streaming | `rah_keys` | B04 | Supports list and stream.
| `/types/{bucket_type}/buckets/{bucket}/keys` | `riak_kv_wm_keylist` | required_streaming | `rah_keys` | B04 | Typed list/stream key mode.
| `/riak/{bucket}` `POST` (server-generated key) | `riak_kv_wm_object` | core_required | `rah_object` | B02 | Legacy create-by-POST path.
| `/buckets/{bucket}/keys` `POST` | `riak_kv_wm_object` | core_required | `rah_object` | B02 | Server-generated key.
| `/types/{bucket_type}/buckets/{bucket}/keys` `POST` | `riak_kv_wm_object` | core_required | `rah_object` | B02 | Typed server-generated key.
| `/riak/{bucket}/{key}` | `riak_kv_wm_object` | core_required | `rah_object` | B02 | Legacy object GET/PUT/POST/DELETE.
| `/buckets/{bucket}/keys/{key}` | `riak_kv_wm_object` | core_required | `rah_object` | B02 | Default object path.
| `/types/{bucket_type}/buckets/{bucket}/keys/{key}` | `riak_kv_wm_object` | core_required | `rah_object` | B02 | Typed object path.
| `/buckets/{bucket}/index/{field}/{term_or_range}` | `riak_kv_wm_index` | required_streaming | `rah_index` | B04 | Supports pagination and stream mode.
| `/types/{bucket_type}/buckets/{bucket}/index/{field}/{term_or_range}` | `riak_kv_wm_index` | required_streaming | `rah_index` | B04 | Typed index lookup.
| `/buckets/{bucket}/counters/{key}` | `riak_kv_wm_counter` | core_required | `rah_counter` | B06 | Legacy counter endpoint.
| `/types/{bucket_type}/buckets/{bucket}/datatypes` | `riak_kv_wm_crdt` | core_required | `rah_crdt` | B06 | Server-generated datatype key on POST.
| `/types/{bucket_type}/buckets/{bucket}/datatypes/{key}` | `riak_kv_wm_crdt` | core_required | `rah_crdt` | B06 | Datatype GET/POST.
| `/riak/{bucket}/{key}/{walk...}` | `riak_kv_wm_link_walker` | deferred_legacy | `rah_link_walker` | deferred | Deprecated with security constraints.
| `/buckets/{bucket}/keys/{key}/{walk...}` | `riak_kv_wm_link_walker` | deferred_legacy | `rah_link_walker` | deferred | Legacy traversal compatibility only.
| `/types/{bucket_type}/buckets/{bucket}/keys/{key}/{walk...}` | `riak_kv_wm_link_walker` | deferred_legacy | `rah_link_walker` | deferred | Typed walk path is security-limited.
| `/cachedtrees/nvals/{nval}/{root|branch|keysclocks}` | `riak_kv_wm_aaefold` | deferred_legacy | `rah_aaefold` | deferred | AAE operational endpoints.
| `/rangetrees/...`, `/rangerepl/...`, `/rangerepair/...` | `riak_kv_wm_aaefold` | deferred_legacy | `rah_aaefold` | deferred | Repair/repl maintenance paths.
| `/siblings/...`, `/objectsizes/...`, `/objectstats/...` | `riak_kv_wm_aaefold` | deferred_legacy | `rah_aaefold` | deferred | Diagnostic/reporting paths.
| `/tombs/...`, `/reap/...`, `/erase/...`, `/aaebucketlist` | `riak_kv_wm_aaefold` | deferred_legacy | `rah_aaefold` | deferred | Tombstone and maintenance flows.
| `/queuename/{name}` | `riak_kv_wm_queue` | deferred_legacy | `rah_queue` | deferred | Replication queue fetch.
| `/membership_request` | `riak_kv_wm_queue` | deferred_legacy | `rah_queue` | deferred | Queue membership control.

## Notes

- `riak_kv_web:raw_dispatch/1` emits some repeated route forms through prefix expansion (`types/{bucket_type}` and default prefix). Inventory above is canonicalized to unique templates.
- Endpoint families mapped to B02-B06 align with the migration batch structure in `docs/plans/2026-02-19-cowboy-interface-design.md`.
