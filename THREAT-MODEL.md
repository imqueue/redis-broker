# Threat model — UDP broker discovery

This is the canonical write-up of what the announcement channel exposes, why the
design accepts it, and what you have to do about it. `SECURITY.md` covers how to
report a vulnerability; this covers the one that is already known and deliberate.

It applies to both announcer modules and to every deployment of them, container
or not.

## 1. What an attacker can do

**Anyone who can send a UDP datagram to port 63000 on the discovery address can
announce a broker `up`, or announce an existing broker `down`.** There is no
signature, no shared secret and no sequence number on the datagram. It carries a
name, a GUID, a status, a `host:port`, an interval and a transport marker, and
any of them can be made up.

Reaching the port is the whole of the attack. Nothing else is required — no
credential, no prior connection, and no read access to anything.

## 2. Blast radius, concretely

**Announcing a hostile broker** puts an attacker-controlled address into every
discovering client's rotation. `ClusteredRedisQueue` spreads sends across the
fleet by round-robin, so a share of real **requests** — arguments included —
arrive at the attacker's Redis, and the replies those callers wait for never come.

**Announcing `down` for a real broker** evicts it immediately; a graceful `down`
is not rate-limited or corroborated. Clients that have already moved on miss the
replies still in flight on it. Repeated at intervals, this is a denial of service
against a fleet that otherwise looks healthy.

**The amplifier: announcements are not filtered by queue name.** Every cluster
registered with a manager on that address and port receives every announcement
sent there. Two unrelated fleets sharing a network segment and the default
`REDIS_BROADCAST_NAME` will discover each other's brokers without anyone
attacking anything — so the accident and the attack are the same mechanism, and
the first is much more likely than the second.

## 3. Required controls

1. **A `NetworkPolicy` confining 63000/udp and 6379/tcp to the namespace.**
   `deploy/*/networkpolicy.yaml` is the starting point. This is the control that
   makes the rest of this document acceptable rather than alarming — without it,
   everything above is reachable from wherever your network reaches.
2. **A distinct `REDIS_BROADCAST_NAME`, and preferably `REDIS_BROADCAST_PORT`,
   per fleet.** This is what stops the accidental case in §2.
3. **`SELECTED_INTERFACES` pinned to the pod CIDR** (unicaster). A broker that
   announces a host or bridge address is discovered and then unreachable, which
   looks like an intermittent fault rather than a misconfiguration.
4. **RBAC scoped to `list` on `pods`, in one namespace** (unicaster).
   `deploy/unicaster/rbac.yaml` grants exactly that. Do not widen it.
5. **`IMQ_REQUIREPASS_FILE` set.** It does not protect discovery — see §4 — but
   it means a hostile broker cannot also be *read* by the fleet, and a real
   broker cannot be read by whoever found the port.
6. **TLS with client certificates** (`IMQ_TLS_*`, `IMQ_TLS_AUTH_CLIENTS=yes`).
   It does not authenticate discovery either, and it is not required for the
   argument in §4 to hold — but it is the control that makes a hostile
   announcement close to useless: see §4.

## 4. Why this is acceptable

**The trust boundary is the namespace, and it is the same boundary that already
protects Redis itself.** An attacker who can send UDP to 63000 can, on any normal
network, also open a TCP connection to 6379 — where, without a password, they can
read every queued message and run `FLUSHALL`. The discovery channel does not
create a new perimeter; it sits inside the one you already have to defend.

Put plainly: if the announcement channel is exposed, you have a bigger problem
one port away. That is the argument, and it holds exactly as far as the
`NetworkPolicy` in §3.1 does.

Authentication does not change this. `requirepass` protects the **data path**;
the datagram carries no credential and is never authenticated, so a password
turns "an attacker can read your queues" into "an attacker can disrupt your
routing". Both are worth preventing, and the same control prevents them.

TLS does not change it either, but it moves the line further. With
`IMQ_TLS_AUTH_CLIENTS=yes` and a CA that is yours, a broker announced at an
attacker's address has to present a certificate signed by that CA before any
client will send it a single message — so announcing a hostile broker stops
being a way to *read* traffic and is only a way to *lose* it. The `down` attack
in §2 is untouched: evicting a real broker needs no certificate.

## 5. What would change it

The `tls`/`plain` marker on the datagram is **not** a signal to trust. It says
which port was announced, so an operator and a log can tell; no client turns
encryption on or off because of it, and none should — that would let an unsigned
UDP packet decide whether a connection is encrypted, which is the whole of this
section in reverse.

There is **no signing, HMAC or nonce on the announcement today**, and adding one
is not on the roadmap. It would need a shared secret distributed to every broker
and every client, which is the same distribution problem as the Redis password
and would have to stay in step with it — and the payoff is bounded by the fact
that the port has to be reachable for any of it to matter.

If your threat model puts an untrusted party inside the namespace, this design
does not defend against them and is not intended to. Use a static
`cluster: [...]` list instead of `UDPClusterManager`: it gives up automatic
scaling and gains a fleet that cannot be altered from the network.
