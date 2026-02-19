#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${ROOT_DIR}"

FAMILIES=(
  "inventory:cowboy_contract_inventory_test"
  "routing:riak_admin_api_app_test"
  "request_normalization:riak_admin_api_request_test"
  "object_crud:riak_admin_api_object_crud_test"
  "bucket_type:riak_admin_api_bucket_type_test"
  "keylist_2i:riak_admin_api_keylist_index_test"
  "query_mapred:riak_admin_api_query_mapred_test"
  "crdt_counter:riak_admin_api_crdt_counter_test"
)

failures=0
passes=0

echo "Cowboy contract harness"
echo "repo=${ROOT_DIR}"
echo "families=${#FAMILIES[@]}"

for entry in "${FAMILIES[@]}"; do
  family="${entry%%:*}"
  module="${entry#*:}"
  cmd=(./rebar3 eunit apps=riak_admin_api --module="${module}")

  echo
  echo "=== family=${family} module=${module} ==="
  echo "+ ${cmd[*]}"

  if "${cmd[@]}"; then
    echo "RESULT family=${family} status=pass"
    passes=$((passes + 1))
  else
    echo "RESULT family=${family} status=fail"
    failures=$((failures + 1))
  fi
done

echo
echo "SUMMARY pass=${passes} fail=${failures} total=${#FAMILIES[@]}"

if (( failures > 0 )); then
  exit 1
fi

