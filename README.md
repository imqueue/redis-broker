# @imqueue redis-broker

A Redis image that announces itself, so an [@imqueue](https://imqueue.org/) fleet
can discover its brokers at runtime instead of being told about them.

```bash
docker run --rm -p 6379:6379 ghcr.io/imqueue/redis-broker:7.4
```

That is a working broker on a bridge network. Point a service at it with
`clusterManagers: [new UDPClusterManager()]` and starting or stopping a container
*is* the scaling operation — no config pushes, no redeploys.

**It announces by default.** `IMQ_BROKER_MODE` defaults to `promoter`, which
shouts to `255.255.255.255:63000` once a second. That is what makes the command
above work with no arguments; if you do not want it, set `IMQ_BROKER_MODE=none`
and you have a plain Redis with a sensible broker config. The datagram is
unauthenticated — read [THREAT-MODEL.md](./THREAT-MODEL.md) before running this
anywhere you would not run an unauthenticated Redis.

## Which mode

One question decides it: **does your network deliver broadcast?**

| | `IMQ_BROKER_MODE` | Where |
|---|---|---|
| Broadcast works | `promoter` | bare metal, VMs, a Docker bridge, your laptop |
| Broadcast is dropped | `unicaster` | GCP VPCs, most Kubernetes overlays |
| No announcing | `none` | a plain Redis, or you supply a static `cluster: [...]` |

Both modules ship in every image and exactly one is ever loaded — two announcers
would double-announce the same broker. The service side is identical either way,
which is the reason this is one image rather than two: you often cannot answer
the broadcast question until the pod is scheduled, and by then you have already
had to choose a tag.

`unicaster` asks the Kubernetes API for its namespace's pod IPs and unicasts the
same datagram to each. It needs a ServiceAccount and a Role granting `list` on
`pods` — see [`deploy/unicaster/`](./deploy/unicaster/), and apply `rbac.yaml`
first. Without it the container refuses to start rather than discovering nothing
quietly.

## Configuration

Environment variables compose a real `redis.conf`. Run with
`IMQ_PRINT_CONFIG=1` to see exactly what they produced.

| Variable | Default | Effect |
|---|---|---|
| `IMQ_BROKER_MODE` | `promoter` | `promoter` \| `unicaster` \| `none` |
| `IMQ_KEYSPACE_EVENTS` | — | **Adds** flags to the mandatory `Ex`. Cannot subtract |
| `IMQ_PERSISTENCE` | `rdb` | `off` \| `rdb` \| `aof` \| `both` |
| `IMQ_REQUIREPASS` | — | Redis password. Prefer the `_FILE` form |
| `IMQ_REQUIREPASS_FILE` | — | Read the password from a file, so it stays out of `docker inspect` and the process environment |
| `IMQ_ACL` | `auto` | `auto` \| `on` \| `off` — see *The config lock* |
| `IMQ_MAXMEMORY` | — | `maxmemory`. The policy is always `noeviction` |
| `IMQ_REDIS_CONF` | — | Path to your own config, included first so everything above overrides it |
| `IMQ_PRINT_CONFIG` | `0` | Print the composed config and exit without starting Redis |

The announcer modules read their own variables directly: `REDIS_BROADCAST_NAME`
(default `imq-broker`), `REDIS_BROADCAST_PORT` (`63000`),
`REDIS_BROADCAST_INTERVAL` (`1`), and — unicaster only — `SELECTED_INTERFACES`
and `DEPLOYMENT_ENV`.

> **`DEPLOYMENT_ENV` is the Kubernetes namespace**, despite the name. It is
> interpolated into `/api/v1/namespaces/<value>/pods`, so a value like
> `production` is only correct if that is literally your namespace. Unset, the
> module requests `/namespaces//pods`, discovers nothing, and reports nothing —
> which is why this image refuses to start without it.

### Keyspace events are a startup decision

`notify-keyspace-events` is set to `Ex` in the config, and **cannot be changed
once the server is up**. `E` delivers `__keyevent@<db>__` and `x` is the expired
class; together they drive @imqueue's delayed messages, and without them `delay`
silently does nothing.

`IMQ_KEYSPACE_EVENTS` adds to that floor at container-start time and is validated
character by character before Redis launches:

```bash
docker run -e IMQ_KEYSPACE_EVENTS=Kl ghcr.io/imqueue/redis-broker:7.4
#   notify-keyspace-events "ExKl"
```

Note that `A` is shorthand for `g$lshzxetd` — it covers `x` but **not** `E`, so
the floor still contributes. `CONFIG GET` reports the flags in Redis's own order
(`Ex` reads back as `xE`); compare them as a set.

### The config lock

By default no connected client can change the running configuration:

```
user default on <cred> ~* &* +@all -config +config|get -module +module|list
```

`CONFIG SET`, `CONFIG REWRITE` and `MODULE LOAD` are denied. **`CONFIG GET` and
`MODULE LIST` stay allowed on purpose** — they are how you verify what actually
took effect, and a lock you cannot inspect is worth less than one you can.

This is broader than the keyspace flags: it freezes *every* runtime tunable, so
the configuration is a property of the deployment manifest rather than of
whoever last had a `redis-cli` prompt. That is the intent. `IMQ_ACL=off` releases
it if you are managing ACLs yourself through `IMQ_REDIS_CONF`.

It needs ACL, which is Redis **6.0+**. On anything older, `IMQ_ACL=auto` falls
back to `requirepass` alone and says so loudly at startup; `IMQ_ACL=on` refuses
to start instead, so a deployment that depends on the guarantee cannot silently
lose it.

*Deny-then-re-allow (`-config +config|get`) rather than `-config|set`: subcommand
denial is Redis 7.0+ and errors out on 6.x, while subcommand allow works from
6.0. The portable form is also the stricter one.*

### Authentication

Off by default, and you should turn it on:

```bash
docker run -e IMQ_REQUIREPASS_FILE=/run/secrets/pw \
           -v /path/to/pw:/run/secrets/pw:ro \
           ghcr.io/imqueue/redis-broker:7.4
```

Clients pass `password` in their connection options — no `username`, because
this authenticates as the `default` ACL user precisely so the client half does
not change across the version gate.

**Every broker in one discovered fleet must share the same password.** Per-entry
`username`/`password` on `cluster` entries are ignored client side; the queues
authenticate with the top-level credentials. The announcement datagram carries a
`host:port` and no credential, so a broker announcing itself with a different
secret is discovered and then unreachable — an intermittent failure that looks
like a network fault.

Auth protects the data path only. It does not authenticate discovery; see
[THREAT-MODEL.md](./THREAT-MODEL.md).

### Persistence

`IMQ_PERSISTENCE=off` is the fastest and loses **every queued and every delayed
message** on restart. `rdb` (the default), `aof` and `both` trade that for disk.

Whenever persistence is on, this image sets `stop-writes-on-bgsave-error no`.
Redis defaults it to `yes`, which turns a failed background save — a full disk, a
bad volume permission — into a refusal of *all writes* while reads keep
answering: a total producer outage on a queue that still looks alive.

`maxmemory-policy` is always `noeviction`, and `--maxmemory-policy` on the
command line is refused. Under any `allkeys-*` policy Redis evicts queue keys,
and messages disappear with no error on either side.

## Using this as a base

The composed config is deliberately readable, and
[`conf/redis-broker.conf.template`](./conf/redis-broker.conf.template) explains
every mandatory line. To start from what this image would do and edit it:

```bash
docker run --rm -e IMQ_PRINT_CONFIG=1 ghcr.io/imqueue/redis-broker:7.4 > redis.conf
```

Then either mount it back (`IMQ_REDIS_CONF=/path/redis.conf`, included first so
this image's guarantees still win), or fork the repo, or build on top with
`FROM ghcr.io/imqueue/redis-broker:7.4`.

Three things are load-bearing; the rest are defaults:

- **the `Ex` floor** — without it, delayed messages never fire;
- **database 0** — @imqueue's watcher subscribes to `__keyevent@0__:expired`,
  hardcoded;
- **one password per fleet** — see *Authentication*.

## Tags

`ghcr.io/imqueue/redis-broker:<redis-version>`, plus an immutable
`:<redis-version>-<broker-version>` and `:latest` following the newest supported
Redis. Published for **7.2** and **7.4**, `linux/amd64` and `linux/arm64`.

### Older Redis

The image builds and passes its smoke test on **6.2** —
`docker build --build-arg REDIS_VERSION=6.2 .` — and CI checks that claim rather
than asserting it. It is **not published**, because a tag is a promise to rebuild
when a CVE lands and 6.2 is end of life upstream. Build your own if you are
pinned to it.

Below 6.0 there is no ACL, so the config lock is unavailable; the image still
runs and still sets the keyspace floor, and tells you what is unprotected.

*TLS is deliberately out of scope for now. `tls-port` plus certificate mounting
is a configuration surface of its own, and it would not cover the discovery
channel either way.*

## Building

```bash
git clone --recurse-submodules https://github.com/imqueue/redis-broker.git
cd redis-broker
docker build -t redis-broker:test .
test/smoke.sh redis-broker:test
```

The two announcers are git submodules pinned to a commit, so the exact module
source in any image is visible in this repository's history:

- [redis-broker-promoter](https://github.com/imqueue/redis-broker-promoter) — broadcast
- [redis-broker-unicaster](https://github.com/imqueue/redis-broker-unicaster) — Kubernetes unicast

Those repositories remain the source of truth and are not forked here. This one
only packages them.

## Licence

GPL-3.0-only, or a commercial licence for closed-source distribution — the same
as the rest of @imqueue. It is **not** AGPL: running it as a network service is
not distribution, so internal services and SaaS carry no source-release
obligation. <https://imqueue.com/license/>

## See also

- [Auto-scaling Redis broker: with and without broadcast](https://imqueue.org/blog/horizontally-scalable-redis-broker/) — the architecture this image implements
- [imqueue.org](https://imqueue.org/) · [llms.txt](https://imqueue.org/llms.txt) for agents
