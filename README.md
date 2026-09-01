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
| `IMQ_TLS` | `auto` | `auto` \| `on` \| `off`. `auto` turns TLS on as soon as a certificate is mounted |
| `IMQ_TLS_CERT_FILE` | — | This broker's certificate |
| `IMQ_TLS_KEY_FILE` | — | Its private key. Both are required together |
| `IMQ_TLS_CA_FILE` | — | The CA whose **client** certificates this broker accepts |
| `IMQ_TLS_KEY_PASSPHRASE_FILE` | — | Passphrase for an encrypted key, read from a file |
| `IMQ_TLS_AUTH_CLIENTS` | `yes` | `yes` \| `no` \| `optional`. `yes` is mTLS and needs `IMQ_TLS_CA_FILE` |
| `IMQ_TLS_PORT` | `6379` | `6380` when the plaintext listener stays up |
| `IMQ_TLS_PLAINTEXT` | `off` | Keep the cleartext listener alongside TLS |
| `IMQ_REDIS_CONF` | — | Path to your own config, included first so everything above overrides it |
| `IMQ_PRINT_CONFIG` | `0` | Print the composed config and exit without starting Redis |

The announcer modules read their own variables directly: `REDIS_BROADCAST_NAME`
(default `imq-broker`), `REDIS_BROADCAST_PORT` (`63000`),
`REDIS_BROADCAST_INTERVAL` (`1`), `REDIS_BROADCAST_TLS` (unset — see *TLS*), and
— unicaster only — `SELECTED_INTERFACES` and `DEPLOYMENT_ENV`.

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

### TLS

Mount a certificate and a key, and the broker serves TLS. Nothing else changes:

```bash
docker run -v /path/to/tls:/run/tls:ro \
           -e IMQ_TLS_CERT_FILE=/run/tls/broker.crt \
           -e IMQ_TLS_KEY_FILE=/run/tls/broker.key \
           -e IMQ_TLS_CA_FILE=/run/tls/ca.crt \
           ghcr.io/imqueue/redis-broker:7.4
```

Three consequences, and they are the whole design:

**The cleartext listener goes away.** Redis serves TLS by setting `port 0` and
`tls-port <n>` — there is no "both" unless you ask for it with
`IMQ_TLS_PLAINTEXT=on`.

**The TLS port is 6379**, the port your Service, NetworkPolicy, probes and
runbooks already name, so turning TLS on is one variable and no manifest churn.
It becomes 6380 only when the plaintext listener stays up, because two listeners
cannot share a port.

**The announcement follows the listener.** `port 0` is how Redis is told to stop
listening in cleartext, and the announcers used to advertise `port` verbatim — so
a TLS broker announced `<ip>:0`, an address nothing can connect to, and one that
`UDPClusterManager` discards as malformed. The fleet discovered no broker at all
and no log said why. The modules now announce whichever listener is up, and mark
the datagram `tls` or `plain`. When both are up, plaintext is announced, because
that is what an already-running fleet is connected to; `REDIS_BROADCAST_TLS=1`
picks the TLS port instead.

Whatever you ask for, the container refuses to start rather than announcing a
port that is not listening or serving cleartext where TLS was requested.

#### Certificates, when the broker's address is not knowable in advance

A broker gets its IP from the scheduler and announces it. Nothing can issue a
certificate for that address ahead of time, and there is no name to use either —
the fleet is found by announcement, not by DNS. So issue **one certificate for
the fleet**, carrying a name that will never be resolved, and have clients pin
that name:

```bash
openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
    -subj /CN=imq-broker-ca -keyout ca.key -out ca.crt

openssl req -newkey rsa:2048 -nodes -subj /CN=imq-broker.internal \
    -keyout broker.key -out broker.csr
openssl x509 -req -in broker.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -days 365 -extfile <(printf 'subjectAltName=DNS:imq-broker.internal') \
    -out broker.crt
```

The service side, in `@imqueue/core`:

```bash
IMQ_REDIS_TLS_CA_FILE=/run/tls/ca.crt
IMQ_REDIS_TLS_SERVERNAME=imq-broker.internal
IMQ_REDIS_TLS_CERT_FILE=/run/tls/client.crt   # when IMQ_TLS_AUTH_CLIENTS=yes
IMQ_REDIS_TLS_KEY_FILE=/run/tls/client.key
```

`servername` is not a hostname to connect to: Node compares it against the
certificate and never resolves it, while the connection still goes to the
announced IP. That is what decouples certificate identity from an address the
scheduler owns — and it means a broker pod that dies and comes back on a
different IP needs no new certificate.

#### Client certificates

`IMQ_TLS_AUTH_CLIENTS` is `yes` by default: every client must present a
certificate signed by `IMQ_TLS_CA_FILE`. Encryption without it leaves the broker
open to anyone who can reach the port, which — given the discovery channel is
unauthenticated — is the half of the problem worth keeping. `no` encrypts
without authenticating; `optional` accepts both and is a migration state, not a
destination.

#### Rotating certificates

Both halves of the fleet read their material once, at start. Rotation is
therefore a rolling restart, and the CAs have to overlap: distribute a CA bundle
containing old and new, roll the brokers onto the new certificate, roll the
services, then drop the old CA from the bundle.

#### Turning it on for a fleet that is already running

The announcement carries **one** transport for the whole fleet, so this is a
cutover rather than an overlap: while the announcement says `plain`, a
TLS-configured service cannot use it, and vice versa. Keep the window short:

1. Brokers: certificates plus `IMQ_TLS_PLAINTEXT=on`. Both listeners are up, the
   announcement is unchanged, and nothing in the fleet notices. Verify by hand
   with `redis-cli --tls --cacert ca.crt --sni imq-broker.internal -p 6380 PING`.
2. Roll the services with their TLS options, and the brokers with
   `REDIS_BROADCAST_TLS=1`, together. Services reconnect over TLS as their
   discovery refreshes.
3. Drop `IMQ_TLS_PLAINTEXT` and `REDIS_BROADCAST_TLS`. The TLS listener moves
   back to 6379 and is the only one left.

The `tls`/`plain` marker on the datagram exists so that a client could one day
choose per broker and make step 2 a rolling change; `@imqueue/core` does not read
it today, and reading it would mean letting an unauthenticated datagram decide
whether to encrypt — which is a decision that needs more than a UDP packet
behind it.

#### What TLS here does and does not cover

It encrypts and authenticates the **data path** — the connection between a
service and a broker. It does not authenticate **discovery**: the datagram is
still unsigned, and a hostile one can still name any address. What changes is
what an attacker gains by it: with `IMQ_TLS_AUTH_CLIENTS=yes` and a private CA, a
broker at an announced address that cannot present a certificate from your CA
gets no connection and no message. Read [THREAT-MODEL.md](./THREAT-MODEL.md) for
the rest.

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

And one thing a fork has to keep in step: **whichever port is listening is the
port that must be announced**. Compose `tls-port` yourself and the announcer
still reads the running config, so it follows — but hand-writing `port 0` while
expecting `port` to be advertised is the failure this image now refuses to
produce.

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

TLS needs a Redis built with `BUILD_TLS=yes`, which the official images are from
**6.2** on. On a build without it the image refuses to start rather than letting
Redis die on an unknown directive.

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

**ISC** — this repository and the two announcer modules it packages. Permissive:
use it, change it, ship it inside anything, no source-release obligation and no
commercial licence needed.

That is deliberately *not* the rest of @imqueue, which is GPL-3.0-only with a
commercial option (<https://imqueue.com/license/>). The broker layer is
infrastructure you run rather than a library you build against, so the licence
should never be a reason to hesitate over it.

**What is in the image, and under what terms.** The `.so` modules and everything
in this repository are ISC. The base image is the official `redis`, and Redis's
own licence changed at 7.4: **7.2 is BSD-3-Clause**, while **7.4 is dual
RSALv2 / SSPLv1**, which permits redistribution but restricts offering Redis
itself as a managed service. If that distinction matters to you, build on 7.2 —
`docker build --build-arg REDIS_VERSION=7.2 .` — or bring your own base.

## See also

- [Auto-scaling Redis broker: with and without broadcast](https://imqueue.org/blog/horizontally-scalable-redis-broker/) — the architecture this image implements
- [imqueue.org](https://imqueue.org/) · [llms.txt](https://imqueue.org/llms.txt) for agents
