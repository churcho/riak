# D01 Distribution Behavior Matrix

Date: 2026-02-20
Status: Baseline behavior contract

## Endpoint Behavior Matrix

| Endpoint group | Read/Write | Default policy | Remote behavior | Failure contract | Consistency contract |
|---|---|---|---|---|---|
| `object_item` (`GET/HEAD`) | Read | `local_first` | Optional single-target forward; no fanout by default | Local timeout -> existing `503 timeout`; remote target timeout -> `503 dc_timeout` | Existing Riak read quorum semantics in selected DC |
| `object_item` (`PUT/POST/DELETE`) | Write | `local_only` | No automatic forwarding | Existing object error envelope (`409/412/503/...`) | Existing Riak write quorum semantics in local DC |
| `object_collection` (`POST`) | Write | `local_only` | No automatic forwarding | Existing create-path contract (`201/200/4xx/5xx`) | Local DC only |
| `bucket_props`/`bucket_type_props` read | Read | `local_first` | Optional explicit forward | Remote unreachable -> `503 dc_unreachable` | Metadata read from selected DC |
| `bucket_props`/`bucket_type_props` mutate | Write | `local_only` | Disabled by default | Existing mutation error contract | Local DC only |
| `keys` | Read | `local_first` | Optional explicit forward | Stream timeout contracts unchanged for local path; remote timeout uses DC error envelope | Read visibility depends on selected DC |
| `index_query` | Read | `local_first` | Optional explicit forward; aggregation deferred | Remote timeout -> `503 dc_timeout` | Selected-DC index state |
| `query` | Read | `local_first` | Optional explicit forward | Query validation unchanged; remote failure wrapped as DC error | Selected-DC query state |
| `mapred` (`POST`) | Compute | `local_only` | Explicit forward disabled by default | Existing mapred status/error behavior preserved | Local execution only |
| `counter`/`crdt_item` (`GET`) | Read | `local_first` | Optional explicit forward | Remote failure uses DC error envelope | Selected-DC CRDT state |
| `counter`/`crdt_item`/`crdt_collection` (`POST`) | Write | `local_only` | No automatic forwarding | Existing CRDT error contract | Local convergence only |
| `/api/dcs` | Aggregate read | `aggregate_read` | Fanout via syn membership view | If at least one source available: `200` with `partial=true` when needed | Best-effort aggregate summary |
| `/api/cluster/status` | Aggregate read | `aggregate_read` | Local ring + remote DC metadata append | `200` with partial flags if remote DC subset unavailable | Local ring authoritative, remote fields advisory |

## Client-Facing Distribution Envelope

For D01-specific remote/aggregate outcomes, response envelope adds:

- `served_by_dc`: DC that produced the payload.
- `target_dc`: explicit forward target (when used).
- `partial`: boolean for aggregate partial success.
- `unavailable_dcs`: list of DC names that failed.
- `dc_errors`: map/list of `{dc, status, error_code}` entries.

Existing `request_id`, `status`, `error`, and `reason` contracts remain mandatory.

## Policy Resolution Precedence

1. Endpoint policy class (`local_only` / `local_first` / `remote_forward` / `aggregate_read`).
2. Per-endpoint op-mode guardrails (cutover and distribution toggles).
3. Explicit target selector (`x-riak-target-dc`) if policy allows.
4. Local health gates and timeout budgets.
5. Fallback/aggregate merge logic.

## Non-Goals in This Pass

- No transparent multi-target write fanout.
- No new public route introduction.
- No compatibility-breaking status/code changes for existing local execution paths.
