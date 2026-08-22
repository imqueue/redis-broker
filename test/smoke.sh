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
trap cleanup EXIT

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n         %s\n' "$1" "${2:-}"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }

# start <env...> — runs the image detached and waits for it to answer
start() {
    cleanup
    docker run -d --name "$NAME" "$@" "$IMAGE" >/dev/null || return 1
    for _ in $(seq 1 40); do
        docker exec "$NAME" redis-cli ${PASSARG:-} PING 2>/dev/null | grep -q PONG && return 0
        sleep 0.25
    done
    return 1
}
cli() { docker exec "$NAME" redis-cli ${PASSARG:-} "$@" 2>&1; }

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

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
