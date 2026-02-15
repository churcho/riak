# Riak - a distributed, decentralised data storage system.

## Build Status

| Component  |     Status      |
|:----------|:-------------:|
| riak_core |  ![Riak Core OpenRiak Status](https://github.com/OpenRiak/riak_core/actions/workflows/erlang.yml/badge.svg?branch=openriak-4.0) |
| riak_kv |    ![Riak KV OpenRiak Status](https://github.com/OpenRiak/riak_kv/actions/workflows/erlang.yml/badge.svg?branch=openriak-4.0)  |
| leveled | ![Leveled OpenRiak Status](https://github.com/OpenRiak/leveled/actions/workflows/erlang.yml/badge.svg?branch=openriak-4.0) |
| kv_index_tictactree | ![Tictac Tree OpenRiak Status](https://github.com/OpenRiak/kv_index_tictactree/actions/workflows/erlang.yml/badge.svg?branch=openriak-4.0) |
| bitcask | ![Bitcask OpenRiak Status](https://github.com/OpenRiak/bitcask/actions/workflows/erlang.yml/badge.svg?branch=openriak-4.0) |

## OTP version support

Riak is built on top of the [Erlang/OTP platform](https://github.com/erlang/otp).  Supported versions for this release are:

![OTP Recommended](https://img.shields.io/badge/OTP_Recommended_Version-_OTP_28_-green)

![OTP Supported](https://img.shields.io/badge/OTP_Backwards_Compatible-_OTP_26_-blue)

For other OTP versions, an alternative `openriak-<release>` branch will be required.  See [the roadmap discussion](https://github.com/orgs/OpenRiak/discussions/19) for further details.

## Why Riak?

Riak is a distributed key-value store, designed to provide high-availability with predictable response times in the presence of complex failure scenarios. It can be configured to provide assurance against data loss, even where individual nodes have ephemeral storage, and groups of nodes can be concurrently impacted by failure events. It is a reliable system whilst running on simple, low-cost, commodity components - remaining highly available without the need for urgent operator intervention.

Riak is commonly used as a schema-free database for the storage and indexing of records, documents, objects or binaries with minimal constraints imposed by the database. In functional terms, Riak can be considered to be a hybrid combination of some of the features available within S3 and DynamoDB.

Riak fully supports multi-cluster environments (within and across physical locations), where open replication is possible not just between Riak clusters, but between Riak clusters and other database services. With Riak, reconciliation is considered as important as replication. Clusters may come in different shapes and sizes - but it is important that as well as replicating data between clusters, it is possible to do rapid and continuous verification that clusters remain synchronised.

Riak users have been running large-scale production databases in mission-critical environments on commodity hardware with more than a decade of continuous uptime. These environments are noted not just for their high availability, but for their low operator-intervention rates. Riak is often preferred in organisations where technology choices need to be long-lasting, and ongoing operational costs are a more important consideration than up-front developer costs.

Riak is built almost entirely using BEAM technology, a platform designed from the start to support the next generation of reliable systems. Over the past few years Riak has been evolved to make better use of the BEAM platform, and is now supported on an ongoing basis by a Working Group of the Erlang Ecosystem Foundation.

## Getting Started

To build Riak, Erlang OTP 28 is recommended.

`make rel` will build a release which can be run via `rel/riak/bin/riak daemon`.  Riak is primarily configured via `rel/riak/etc/riak.conf`

To make a package, install appropriate build tools for your operating system and run `make package`.

To create a local multi-node build environment use `make devclean; make devrel`.

To test Riak use [Riak Test](https://github.com/OpenRiak/riak_test), follow [this guide for quick setup](https://github.com/OpenRiak/riak_test/doc/SIMPLE_SETUP.md).

There is some historic information available in the [legacy documentation](https://docs.riak.com/riak/kv/latest/index.html).  Work on refreshing the documentation is ongoing, and in the interim further documentation is available via Riak support organisations, or in the doc folders of the riak_kv and riak_core repositories.

Issues and PRs can be tracked via [Riak Github](https://github.com/OpenRiak/riak/issues) or [Riak KV Github](https://github.com/OpenRiak/riak_kv/issues).

Discussions on the ongoing development of the OpenRiak version of Riak KV [can be found on Github](https://github.com/orgs/OpenRiak/discussions).

The OpenRiak community is supported by [the Erlang Ecosystem Foundation](https://erlef.org/).

## macOS Apple Silicon Code-Signing

When building Riak on Apple Silicon Macs (M1/M2/M3/M4), `make devrel` copies the Erlang ERTS binaries (`beam.smp`, `erlexec`, `escript`, etc.) from your Erlang installation into each dev node's `erts-*/bin/` directory. Copying a Mach-O binary to a new path invalidates its ad-hoc code signature, and the macOS kernel enforces signature validation by killing unsigned binaries with `SIGKILL` (exit code 137).

**Symptom:** `riak daemon` fails immediately with:

```
Cuttlefish failed! Oh no!:
```

This happens because the `cf_config` startup hook runs `erts-*/bin/escript` to invoke Cuttlefish for config generation, and that binary is killed before it can produce the node's `sys.config` and `vm.args` files. The Erlang VM itself never starts.

**Fix:** The `make devrel` target automatically runs `codesign -fs -` (ad-hoc signing) on all Mach-O binaries after building. If you need to re-sign manually:

```bash
for d in dev/dev*/riak/erts-*/bin/*; do
    file "$d" | grep -q Mach-O && codesign -fs - "$d" 2>/dev/null
done
```

**Platforms affected:**

| Platform | Affected? | Notes |
|----------|-----------|-------|
| macOS Apple Silicon | Yes | Kernel enforces code signatures |
| macOS Intel | Rarely | Less strict enforcement |
| Linux | No | No code-signing enforcement |
| FreeBSD | No | No code-signing enforcement |
| Docker (any host) | No | Linux kernel inside container |
