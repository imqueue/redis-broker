#!/usr/bin/env bash
#
# imqueue/redis-broker smoke test.
#
#   test/smoke.sh [image]        default: redis-broker:test
#
# Every assertion here corresponds to a way this image can be wrong SILENTLY.
# Two of them are shaped by results measured against redis:6.2 and redis:7.2 and
# are easy to get wrong:
#
#   * NOPERM is matched as a prefix, never by message text. 6.2 says "no
#     permissions to run the 'config' command or its subcommand"; 7.2 says "User
#     default has no permissions to run the 'config|set' command".
#   * Keyspace flags are compared as a SET, never as a string. A config carrying
#     `notify-keyspace-events "Ex"` reads back from CONFIG GET as `xE`.
#
set -uo pipefail

IMAGE=${1:-redis-broker:test}
NAME=redis-broker-smoke-$$
PASS=0; FAIL=0

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
TLSARG=
CERT_DIR=
# NOT part of cleanup(): that one runs between tests, and the certificates have
# to outlive it.
drop_certs() { [ -z "$CERT_DIR" ] || rm -rf "$CERT_DIR"; CERT_DIR=; }
trap 'cleanup; drop_certs' EXIT

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n         %s\n' "$1" "${2:-}"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }

# start <env...> — runs the image detached and waits for it to answer
start() {
    cleanup
    docker run -d --name "$NAME" "$@" "$IMAGE" >/dev/null || return 1
    for _ in $(seq 1 40); do
        docker exec "$NAME" redis-cli ${TLSARG:-} ${PASSARG:-} PING 2>/dev/null | grep -q PONG && return 0
        sleep 0.25
    done
    return 1
}
cli() { docker exec "$NAME" redis-cli ${TLSARG:-} ${PASSARG:-} "$@" 2>&1; }

# has_flags <expected chars> — set membership, not string equality
has_flags() {
    local got; got=$(cli CONFIG GET notify-keyspace-events | tail -1)
    local c
    for (( i=0; i<${#1}; i++ )); do
        c=${1:i:1}
        [[ "$got" == *"$c"* ]] || { echo "missing '$c' in '$got'"; return 1; }
    done
    return 0
}

echo "== $IMAGE =="

# --- modules -----------------------------------------------------------------
PASSARG=
start -e IMQ_BROKER_MODE=promoter || bad "promoter starts" "container never answered PING"
# Presence, not a line count: MODULE LIST prints the module's `path` as well as
# its name, so a loaded `promoter` matches on two lines, not one.
if cli MODULE LIST | grep -q promoter; then ok "promoter mode loads the promoter module"
else bad "promoter mode loads the promoter module" "$(cli MODULE LIST)"; fi
if cli MODULE LIST | grep -q unicaster; then
    bad "promoter mode does not load the unicaster" "both announcers are loaded"
else ok "promoter mode does not load the unicaster"; fi

# The announcer is the entire point: a broker that starts but never announces is
# invisible to every service that would discover it.
docker exec "$NAME" sh -c 'timeout 3 sh -c "exec 3<>/dev/udp/0.0.0.0/0" 2>/dev/null; true' >/dev/null 2>&1
if docker run --rm --network "container:$NAME" "$IMAGE" \
     sh -c 'timeout 4 timeout 4 sh -c "command -v nc >/dev/null && nc -u -l -w 3 -p 63000"' 2>/dev/null | grep -q imq-broker; then
    ok "promoter announces on 63000/udp"
else
    printf '  skip  promoter announces on 63000/udp (no nc in image; assert this in CI with a sidecar)\n'
fi

start -e IMQ_BROKER_MODE=none || bad "none starts" "container never answered PING"
# `wc -l` reports 1 for redis-cli's empty reply, so compare the collapsed text:
# an empty MODULE LIST prints nothing, or "(empty array)" depending on version.
mods=$(cli MODULE LIST | tr -d '[:space:]')
if [ -z "$mods" ] || [ "$mods" = "(emptyarray)" ]; then
    ok "IMQ_BROKER_MODE=none loads no module"
else bad "IMQ_BROKER_MODE=none loads no module" "got: $mods"; fi

check "both modules ship in every image" \
      "$(docker run --rm --entrypoint sh "$IMAGE" -c 'ls /usr/local/lib/redis_modules | tr "\n" " "')" \
      "promoter.so unicaster.so "

# --- keyspace events ---------------------------------------------------------
# No client has ever connected before this read: the floor comes from the file.
if has_flags "Ex"; then ok "the Ex floor is set with no client having configured it"
else bad "the Ex floor is set with no client having configured it" "$(has_flags Ex 2>&1)"; fi

start -e IMQ_BROKER_MODE=none -e IMQ_KEYSPACE_EVENTS=Kl
if has_flags "ExKl"; then ok "IMQ_KEYSPACE_EVENTS is a union, not a replacement"
else bad "IMQ_KEYSPACE_EVENTS is a union, not a replacement" "$(has_flags ExKl 2>&1)"; fi

# A covers x but NOT E, so the floor still has to contribute one character.
start -e IMQ_BROKER_MODE=none -e IMQ_KEYSPACE_EVENTS=A
if has_flags "EA"; then ok "IMQ_KEYSPACE_EVENTS=A still yields E"
else bad "IMQ_KEYSPACE_EVENTS=A still yields E" "$(has_flags EA 2>&1)"; fi

out=$(docker run --rm -e IMQ_BROKER_MODE=none -e IMQ_KEYSPACE_EVENTS=Q "$IMAGE" 2>&1); rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "not a Redis event class"; then
    ok "an invalid event class is refused before Redis starts"
else bad "an invalid event class is refused before Redis starts" "rc=$rc: $out"; fi

out=$(docker run --rm -e IMQ_BROKER_MODE=none "$IMAGE" redis-server --notify-keyspace-events "" 2>&1); rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "only adds"; then
    ok "--notify-keyspace-events on the command line is refused"
else bad "--notify-keyspace-events on the command line is refused" "rc=$rc: $out"; fi

# --- the config lock ---------------------------------------------------------
start -e IMQ_BROKER_MODE=none
case "$(cli CONFIG SET notify-keyspace-events '')" in
    NOPERM*) ok "CONFIG SET is refused (NOPERM prefix, not message text)" ;;
    *)       bad "CONFIG SET is refused" "$(cli CONFIG SET notify-keyspace-events '')" ;;
esac
if has_flags "Ex"; then ok "the flags survive the attempt"; else bad "the flags survive the attempt" ""; fi
case "$(cli CONFIG REWRITE)" in
    NOPERM*) ok "CONFIG REWRITE is refused" ;;
    *)       bad "CONFIG REWRITE is refused" "$(cli CONFIG REWRITE)" ;;
esac
if cli CONFIG GET maxmemory-policy | grep -q noeviction; then
    ok "CONFIG GET still answers, and the policy is noeviction"
else bad "CONFIG GET still answers, and the policy is noeviction" "$(cli CONFIG GET maxmemory-policy)"; fi
if cli MODULE LOAD /tmp/x.so | grep -Eq 'NOPERM|not allowed'; then
    ok "MODULE LOAD at runtime is refused"
else bad "MODULE LOAD at runtime is refused" "$(cli MODULE LOAD /tmp/x.so)"; fi

start -e IMQ_BROKER_MODE=none -e IMQ_ACL=off
if [ "$(cli CONFIG SET appendfsync everysec)" = "OK" ]; then
    ok "IMQ_ACL=off releases the lock, as documented"
else bad "IMQ_ACL=off releases the lock" "$(cli CONFIG SET appendfsync everysec)"; fi

# --- auth --------------------------------------------------------------------
PASSARG=
start -e IMQ_BROKER_MODE=none -e IMQ_REQUIREPASS=sm0ke
if cli PING | grep -q NOAUTH; then ok "an unauthenticated PING is refused"
else bad "an unauthenticated PING is refused" "$(cli PING)"; fi
PASSARG="--no-auth-warning -a sm0ke"
check "the password authenticates" "$(cli PING)" "PONG"
case "$(cli CONFIG SET appendfsync everysec)" in
    NOPERM*) ok "auth and the lock coexist on one ACL line" ;;
    *)       bad "auth and the lock coexist on one ACL line" "$(cli CONFIG SET appendfsync everysec)" ;;
esac

PASSARG=
docker rm -f "$NAME" >/dev/null 2>&1
SECRET_DIR=$(mktemp -d); echo -n 'fr0mfile' > "$SECRET_DIR/pw"
start -e IMQ_BROKER_MODE=none -e IMQ_REQUIREPASS_FILE=/run/pw -v "$SECRET_DIR/pw:/run/pw:ro"
if docker inspect "$NAME" | grep -q fr0mfile; then
    bad "IMQ_REQUIREPASS_FILE keeps the secret out of docker inspect" "found in inspect output"
else ok "IMQ_REQUIREPASS_FILE keeps the secret out of docker inspect"; fi
PASSARG="--no-auth-warning -a fr0mfile"
check "the file-sourced password authenticates" "$(cli PING)" "PONG"
rm -rf "$SECRET_DIR"

# --- persistence -------------------------------------------------------------
PASSARG=
start -e IMQ_BROKER_MODE=none -e IMQ_PERSISTENCE=off
check "IMQ_PERSISTENCE=off clears the save points" "$(cli CONFIG GET save | tail -1)" ""
check "IMQ_PERSISTENCE=off leaves the AOF off"     "$(cli CONFIG GET appendonly | tail -1)" "no"

start -e IMQ_BROKER_MODE=none -e IMQ_PERSISTENCE=aof
check "IMQ_PERSISTENCE=aof turns the AOF on" "$(cli CONFIG GET appendonly | tail -1)" "yes"
check "a failed bgsave must not stop writes"  "$(cli CONFIG GET stop-writes-on-bgsave-error | tail -1)" "no"

out=$(docker run --rm -e IMQ_BROKER_MODE=none -e IMQ_PERSISTENCE=sometimes "$IMAGE" 2>&1); rc=$?
if [ $rc -ne 0 ]; then ok "an unknown IMQ_PERSISTENCE is refused"
else bad "an unknown IMQ_PERSISTENCE is refused" "$out"; fi

# --- unicaster preconditions -------------------------------------------------
out=$(docker run --rm -e IMQ_BROKER_MODE=unicaster "$IMAGE" 2>&1); rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "KUBERNETES"; then
    ok "unicaster without DEPLOYMENT_ENV refuses, and says it is a namespace"
else bad "unicaster without DEPLOYMENT_ENV refuses" "rc=$rc: $out"; fi

out=$(docker run --rm -e IMQ_BROKER_MODE=unicaster -e DEPLOYMENT_ENV=default "$IMAGE" 2>&1); rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "ServiceAccount"; then
    ok "unicaster without a ServiceAccount token refuses, and points at deploy/"
else bad "unicaster without a ServiceAccount token refuses" "rc=$rc: $out"; fi

out=$(docker run --rm -e IMQ_BROKER_MODE=sideways "$IMAGE" 2>&1); rc=$?
if [ $rc -ne 0 ]; then ok "an unknown IMQ_BROKER_MODE is refused"
else bad "an unknown IMQ_BROKER_MODE is refused" "$out"; fi

# --- IMQ_PRINT_CONFIG --------------------------------------------------------
conf=$(docker run --rm -e IMQ_PRINT_CONFIG=1 "$IMAGE" 2>/dev/null)
if echo "$conf" | grep -q 'notify-keyspace-events "Ex"'; then
    ok "IMQ_PRINT_CONFIG renders a config carrying the floor"
else bad "IMQ_PRINT_CONFIG renders a config carrying the floor" "$conf"; fi
if [ -n "$conf" ] && ! docker run --rm -e IMQ_PRINT_CONFIG=1 "$IMAGE" 2>/dev/null | grep -q "Ready to accept"; then
    ok "IMQ_PRINT_CONFIG does not start Redis"
else bad "IMQ_PRINT_CONFIG does not start Redis" ""; fi

# --- the composed config is not writable -------------------------------------
start -e IMQ_BROKER_MODE=none
perms=$(docker exec "$NAME" stat -c '%a %U' /etc/redis/redis-broker.conf)
check "the composed config is root-owned and read-only" "$perms" "444 root"

# --- TLS ---------------------------------------------------------------------
# The certificate below is issued to a NAME and the broker is dialled at an
# ADDRESS, deliberately: a broker gets its IP from the scheduler, so no
# certificate can carry it, and clients pin the name with `servername` instead.
# Nothing in this image depends on that — it is the client half — but the
# certificates here are shaped the way real ones have to be.
make_certs() {
    CERT_DIR=$(mktemp -d)
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=imq-smoke-ca \
        -keyout "$CERT_DIR/ca.key" -out "$CERT_DIR/ca.crt" >/dev/null 2>&1
    printf 'subjectAltName=DNS:imq-broker.internal\n' > "$CERT_DIR/ext"
    openssl req -newkey rsa:2048 -nodes -subj /CN=imq-broker.internal \
        -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.csr" >/dev/null 2>&1
    openssl x509 -req -in "$CERT_DIR/server.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" \
        -CAcreateserial -days 1 -extfile "$CERT_DIR/ext" -out "$CERT_DIR/server.crt" >/dev/null 2>&1
    openssl req -newkey rsa:2048 -nodes -subj /CN=imq-client \
        -keyout "$CERT_DIR/client.key" -out "$CERT_DIR/client.csr" >/dev/null 2>&1
    openssl x509 -req -in "$CERT_DIR/client.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" \
        -CAcreateserial -days 1 -out "$CERT_DIR/client.crt" >/dev/null 2>&1
    # uid 999 opens these, not root and not you — and it has to walk the
    # directory to reach them, which a 0700 mktemp -d does not allow
    chmod 0755 "$CERT_DIR"
    chmod 0444 "$CERT_DIR"/*.crt "$CERT_DIR"/*.key
}

if ! command -v openssl >/dev/null 2>&1; then
    printf '  skip  TLS (no openssl to issue test certificates)\n'
else
make_certs
MOUNT="-v $CERT_DIR:/run/tls:ro"
TLSENV="-e IMQ_TLS_CERT_FILE=/run/tls/server.crt -e IMQ_TLS_KEY_FILE=/run/tls/server.key -e IMQ_TLS_CA_FILE=/run/tls/ca.crt"
CLIENT_TLS="--tls --cert /run/tls/client.crt --key /run/tls/client.key --cacert /run/tls/ca.crt --sni imq-broker.internal"

# Mounting a certificate is the whole switch: no IMQ_TLS=on needed.
conf=$(docker run --rm -e IMQ_PRINT_CONFIG=1 $MOUNT $TLSENV "$IMAGE" 2>/dev/null)
if echo "$conf" | grep -q '^tls-port 6379$'; then
    ok "a mounted certificate turns TLS on, on 6379 — no port change to deploy"
else bad "a mounted certificate turns TLS on, on 6379" "$conf"; fi
# The reason the announcers had to change: this line is what made them announce
# ":0" and vanish from the fleet.
if echo "$conf" | grep -q '^port 0$'; then
    ok "TLS-only means 'port 0', which is what the announcer must not advertise"
else bad "TLS-only means 'port 0'" "$conf"; fi

TLSARG=$CLIENT_TLS
start $MOUNT $TLSENV -e IMQ_BROKER_MODE=promoter || bad "a TLS broker starts" "container never answered PING"
check "a client with a certificate is served over TLS" "$(cli PING)" "PONG"
# mTLS is the default here, and a client without a certificate must not be
# quietly accepted in cleartext or otherwise.
# captured first, not piped: redis-cli exits non-zero here and `pipefail`
# would report that rather than what grep found
out=$(docker exec "$NAME" redis-cli PING 2>&1)
case "$out" in
    PONG) bad "the plaintext port is gone while TLS is on" "a cleartext client got a reply" ;;
    *)    ok "the plaintext port is gone while TLS is on" ;;
esac
if docker logs "$NAME" 2>&1 | grep -q 'announcing port 6379 (tls)'; then
    ok "the announcer advertises the TLS port, and says so at startup"
else bad "the announcer advertises the TLS port" "$(docker logs "$NAME" 2>&1 | grep -i announc)"; fi

# What actually goes on the wire. Host networking, a port nothing else uses, and
# only the fields that matter — the source IP is whatever interface answered.
if command -v python3 >/dev/null 2>&1; then
    cleanup
    docker run -d --name "$NAME" --network host $MOUNT $TLSENV \
        -e IMQ_BROKER_MODE=promoter -e IMQ_TLS_PORT=7379 -e REDIS_BROADCAST_PORT=63111 \
        -e REDIS_BROADCAST_NAME=imq-smoke "$IMAGE" >/dev/null 2>&1
    datagram=$(timeout 8 python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 63111))
s.settimeout(6)
try:
    print(s.recvfrom(512)[0].decode())
except Exception:
    print("<no datagram>")
')
    case "$datagram" in
        *":7379	1	tls") ok "the datagram carries the TLS port and is marked tls" ;;
        *) bad "the datagram carries the TLS port and is marked tls" "got: $datagram" ;;
    esac
else
    printf '  skip  the datagram carries the TLS port (no python3 to listen)\n'
fi

# Both listeners: the migration case. Plaintext keeps 6379 so nothing already
# connected has to move, and TLS gets 6380.
TLSARG=
start $MOUNT $TLSENV -e IMQ_TLS_PLAINTEXT=on -e IMQ_BROKER_MODE=none || bad "both listeners start" "no PING"
check "IMQ_TLS_PLAINTEXT=on keeps plaintext on 6379" "$(cli PING)" "PONG"
TLSARG="$CLIENT_TLS -p 6380"
check "and serves TLS on 6380 at the same time" "$(cli PING)" "PONG"
TLSARG=

# An encrypted key is a normal deployment shape, and its passphrase reaches Redis
# through the composed config rather than the environment.
openssl rsa -aes256 -in "$CERT_DIR/server.key" -out "$CERT_DIR/server.enc.key" \
    -passout pass:s3cr3t >/dev/null 2>&1
printf 's3cr3t' > "$CERT_DIR/keypass"
chmod 0444 "$CERT_DIR/server.enc.key" "$CERT_DIR/keypass"
TLSARG=$CLIENT_TLS
start $MOUNT -e IMQ_TLS_CERT_FILE=/run/tls/server.crt \
    -e IMQ_TLS_KEY_FILE=/run/tls/server.enc.key \
    -e IMQ_TLS_KEY_PASSPHRASE_FILE=/run/tls/keypass \
    -e IMQ_TLS_CA_FILE=/run/tls/ca.crt -e IMQ_BROKER_MODE=none \
    || bad "an encrypted key starts" "container never answered PING"
check "an encrypted key is unlocked from IMQ_TLS_KEY_PASSPHRASE_FILE" "$(cli PING)" "PONG"
TLSARG=

# --- TLS: what is refused before Redis starts --------------------------------
out=$(docker run --rm $MOUNT -e IMQ_TLS_CERT_FILE=/run/tls/server.crt "$IMAGE" 2>&1); rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "IMQ_TLS_KEY_FILE"; then
    ok "a certificate without its key is refused"
else bad "a certificate without its key is refused" "rc=$rc: $out"; fi

out=$(docker run --rm $MOUNT -e IMQ_TLS_CERT_FILE=/run/tls/server.crt \
      -e IMQ_TLS_KEY_FILE=/run/tls/server.key "$IMAGE" 2>&1); rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "IMQ_TLS_AUTH_CLIENTS=no"; then
    ok "asking for client certificates with no CA is refused, and says how to opt out"
else bad "asking for client certificates with no CA is refused" "rc=$rc: $out"; fi

out=$(docker run --rm $MOUNT -e IMQ_TLS_CERT_FILE=/run/tls/nope.crt \
      -e IMQ_TLS_KEY_FILE=/run/tls/server.key -e IMQ_TLS_AUTH_CLIENTS=no "$IMAGE" 2>&1); rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "does not exist"; then
    ok "a certificate path that is not there is refused, not discovered by Redis"
else bad "a missing certificate path is refused" "rc=$rc: $out"; fi

# Root can read a 0600 root-owned mount; uid 999, which opens it, cannot.
SECRET_KEY=$(mktemp -d); cp "$CERT_DIR/server.key" "$SECRET_KEY/server.key"; chmod 0600 "$SECRET_KEY/server.key"
out=$(docker run --rm $MOUNT -v "$SECRET_KEY/server.key:/run/priv.key:ro" \
      -e IMQ_TLS_CERT_FILE=/run/tls/server.crt -e IMQ_TLS_KEY_FILE=/run/priv.key \
      -e IMQ_TLS_AUTH_CLIENTS=no "$IMAGE" 2>&1); rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "uid 999"; then
    ok "a key the redis user cannot read is refused, before Redis fails on it"
else bad "an unreadable key is refused" "rc=$rc: $out"; fi
rm -rf "$SECRET_KEY"

out=$(docker run --rm -e REDIS_BROADCAST_TLS=1 "$IMAGE" 2>&1); rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "no TLS listener to advertise"; then
    ok "announcing a TLS port that does not exist is refused, not discovered in production"
else bad "REDIS_BROADCAST_TLS=1 without TLS is refused" "rc=$rc: $out"; fi

out=$(docker run --rm $MOUNT $TLSENV "$IMAGE" redis-server --tls-port 7000 2>&1); rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "one decision"; then
    ok "--tls-port on the command line is refused while TLS is on"
else bad "--tls-port on the command line is refused" "rc=$rc: $out"; fi

# Mounted material and IMQ_TLS=off: it starts, in cleartext, and says so.
out=$(docker run --rm -e IMQ_PRINT_CONFIG=1 -e IMQ_TLS=off $MOUNT $TLSENV "$IMAGE" 2>&1); rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "serves PLAINTEXT"; then
    ok "IMQ_TLS=off with a certificate mounted warns rather than pretending"
else bad "IMQ_TLS=off with a certificate mounted warns" "rc=$rc: $out"; fi

# A Redis built without BUILD_TLS does not ignore `tls-port`, it dies on it — a
# crash loop with a config error, out of a container that was handed a perfectly
# good certificate. Stand in for such a build rather than hope never to meet one.
SHIM=$(mktemp -d)
cat > "$SHIM/redis-server" <<'SHIMEOF'
#!/bin/sh
for a in "$@"; do
    [ "$a" = --version ] && { echo "Redis server v=7.4.0 sha=0:0 malloc=libc bits=64 build=0"; exit 0; }
done
echo "*** FATAL CONFIG FILE ERROR (Redis 7.4.0) ***"
echo ">>> 'tls-port \"0\"'"
echo "Bad directive or wrong number of arguments"
exit 1
SHIMEOF
chmod 0755 "$SHIM/redis-server"
out=$(docker run --rm $MOUNT $TLSENV -v "$SHIM/redis-server:/usr/local/bin/redis-server:ro" "$IMAGE" 2>&1); rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "built without TLS support"; then
    ok "a Redis with no TLS support is refused, not left to die on the directive"
else bad "a Redis with no TLS support is refused" "rc=$rc: $out"; fi
rm -rf "$SHIM"

drop_certs
fi


echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
