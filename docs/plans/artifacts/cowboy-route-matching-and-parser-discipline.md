# Cowboy Route Matching and Parser Discipline

This is mandatory for every migration batch that adds or changes HTTP paths.

## Goal

Keep Cowboy route matching, request parsing, and internal gateway calls in lockstep so no external path is accepted without a correct internal translation.

## Required workflow (for every new/changed route)

1. **Research Cowboy behavior first**
   - Confirm path matching semantics for the target pattern in Cowboy 2.
   - Confirm how optional segments, repeated segments, and trailing slashes behave.
2. **Add route declaration**
   - Add/adjust path in `riak_admin_api_app:substrate_routes/0`.
3. **Add parser normalization**
   - Add/adjust path handling in `riak_admin_api_request:normalize_path/3`.
   - Ensure alias families (`/riak`, `/buckets`, `/types`) normalize to one canonical internal operation.
4. **Add method and query validation**
   - Update `allowed_methods/2` and query normalization rules.
5. **Add dispatch mapping**
   - Ensure `riak_admin_api_handler:dispatch/4` maps operation to the correct handler path.
6. **Add gateway mapping**
   - Ensure gateway call path maps to the exact Riak internal operation expected for that route.
7. **Add tests for route/parser/internal translation**
   - Success path for each alias family.
   - Unknown route and malformed path shape.
   - Method-not-allowed behavior and `allow` contract.
   - Internal translation correctness (operation id, bucket/type/key fields, query semantics).

## Required evidence in batch artifact notes

Each batch parity note must include a "Route Matching Evidence" section with:

- External path template.
- Canonical normalized operation.
- Internal gateway function/action invoked.
- Tests that verify that mapping.

## Non-negotiable guardrails

- Do not parse route path directly inside business handlers.
- Do not add new public paths without parser + tests + gateway translation.
- Do not rely on accidental Cowboy fallback behavior.
- If route semantics are uncertain, document the uncertainty and resolve before shipping.
