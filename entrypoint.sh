#!/bin/sh
#
# imqueue/redis-broker — compose a redis.conf from the environment, then hand off
# to the official redis image's own entrypoint.
#
# Two things this file exists to do, in order of importance:
#
#   1. VALIDATE. Every check below corresponds to a way an @imqueue broker fails
#      *silently* — discovery that finds nothing, delayed messages that never
#      fire, a queue that evicts itself. Each one is cheap to detect here and
#      expensive to notice in production.
#   2. Compose the config. Env vars are what `docker run` and a Kubernetes
#      Deployment speak; a redis.conf is what an operator wants to read, diff and
#      fork. So the entrypoint turns one into the other, and IMQ_PRINT_CONFIG
#      hands you the result.
#
# It WRAPS the upstream entrypoint rather than replacing it: that script does uid
# handling and argument rewriting we have no business reimplementing.
#
set -eu

UPSTREAM=/usr/local/bin/docker-entrypoint.sh
MODULE_DIR=/usr/local/lib/redis_modules
CONF=/etc/redis/redis-broker.conf
TEMPLATE=/usr/local/share/redis-broker/redis-broker.conf.template

# Keyspace-event classes Redis accepts. A character outside this set is a typo,
# and a typo in notify-keyspace-events is a silent delayed-message outage.
#   K keyspace  E keyevent  g generic  $ string  l list  s set  h hash  z zset
#   x expired   e evicted   t stream   d module  m key-miss  n new-key  A = g$lshzxetd
#
# `Ex` is the floor: E delivers __keyevent@<db>__ and x is the expired class.
# @imqueue's delayed messages are driven by expiry, so without both, `delay` does
# nothing and reports nothing.
FLOOR=Ex

die() { printf 'redis-broker: %s\n' "$*" >&2; exit 1; }
note() { printf 'redis-broker: %s\n' "$*" >&2; }

# --- version -----------------------------------------------------------------
# Read from the running binary, not baked in at build time, so this stays correct
# when someone forks this image onto a different Redis.
redis_ver() { redis-server --version | sed -n 's/.*v=\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p'; }

VER=$(redis_ver || true)
[ -n "$VER" ] || die "could not determine the Redis version from 'redis-server --version'"
VER_MAJOR=${VER%%.*}
VER_MINOR=${VER#*.}

# ACL exists from 6.0. Channel patterns (&) only from 6.2 — emitting `&*` on 6.0
# or 6.1 is an error, not a no-op, and on those versions pub/sub was unrestricted
# anyway, so omitting it changes nothing.
HAS_ACL=no
HAS_ACL_CHANNELS=no
if [ "$VER_MAJOR" -ge 7 ]; then
    HAS_ACL=yes; HAS_ACL_CHANNELS=yes
elif [ "$VER_MAJOR" -eq 6 ]; then
    HAS_ACL=yes
    [ "$VER_MINOR" -ge 2 ] && HAS_ACL_CHANNELS=yes
fi

# --- inputs ------------------------------------------------------------------
IMQ_BROKER_MODE=${IMQ_BROKER_MODE:-promoter}
IMQ_KEYSPACE_EVENTS=${IMQ_KEYSPACE_EVENTS:-}
IMQ_PERSISTENCE=${IMQ_PERSISTENCE:-rdb}
IMQ_ACL=${IMQ_ACL:-auto}
IMQ_REQUIREPASS=${IMQ_REQUIREPASS:-}
IMQ_REQUIREPASS_FILE=${IMQ_REQUIREPASS_FILE:-}
IMQ_REDIS_CONF=${IMQ_REDIS_CONF:-}
IMQ_MAXMEMORY=${IMQ_MAXMEMORY:-}
IMQ_PRINT_CONFIG=${IMQ_PRINT_CONFIG:-0}

# --- not our command: get out of the way -------------------------------------
# `docker run … redis-cli`, `sh`, an init container running something else. Only
# a redis-server invocation gets a composed config.
case "${1:-}" in
    redis-server) ;;
    *) exec "$UPSTREAM" "$@" ;;
esac
shift

# --- validate the mode -------------------------------------------------------
case "$IMQ_BROKER_MODE" in
    promoter|unicaster|none) ;;
    *) die "IMQ_BROKER_MODE='$IMQ_BROKER_MODE' is not one of: promoter, unicaster, none" ;;
esac

if [ "$IMQ_BROKER_MODE" = unicaster ]; then
    # DEPLOYMENT_ENV is interpolated straight into
    #   https://kubernetes.default.svc/api/v1/namespaces/%s/pods
    # with an empty-string fallback, so unset means a request to /namespaces//pods
    # that finds no peers and reports no error. It is a NAMESPACE despite the name.
    [ -n "${DEPLOYMENT_ENV:-}" ] || die \
        "IMQ_BROKER_MODE=unicaster needs DEPLOYMENT_ENV, which is the KUBERNETES
  NAMESPACE this broker runs in — not an environment name like 'production',
  unless your namespace is literally called that. Unset, the module asks the API
  for /api/v1/namespaces//pods, discovers nothing, and says nothing.
  Set it from the pod itself:
      env:
        - name: DEPLOYMENT_ENV
          valueFrom: { fieldRef: { fieldPath: metadata.namespace } }"

    [ -r /var/run/secrets/kubernetes.io/serviceaccount/token ] || die \
        "IMQ_BROKER_MODE=unicaster needs a Kubernetes ServiceAccount token at
  /var/run/secrets/kubernetes.io/serviceaccount/token, and a Role granting 'list'
  on pods. See deploy/unicaster/ in this repo for the ServiceAccount, Role and
  RoleBinding. Outside Kubernetes use IMQ_BROKER_MODE=promoter instead."
fi

# --- validate and compose the keyspace flags ---------------------------------
FLAGS=$FLOOR
rest=$IMQ_KEYSPACE_EVENTS
while [ -n "$rest" ]; do
    ch=$(printf '%s' "$rest" | cut -c1)
    rest=$(printf '%s' "$rest" | cut -c2-)
    case "$ch" in
        K|E|g|'$'|l|s|h|z|x|e|t|d|m|n|A) ;;
        *) die "IMQ_KEYSPACE_EVENTS contains '$ch', which is not a Redis event class.
  Valid: K E g \$ l s h z x e t d m n A  (A is shorthand for g\$lshzxetd).
  The variable is ADDITIVE — '$FLOOR' is always set and cannot be removed." ;;
    esac
    case "$FLAGS" in
        *"$ch"*) ;;
        *) FLAGS="$FLAGS$ch" ;;
    esac
done

# --- validate persistence ----------------------------------------------------
case "$IMQ_PERSISTENCE" in
    off|rdb|aof|both) ;;
    *) die "IMQ_PERSISTENCE='$IMQ_PERSISTENCE' is not one of: off, rdb, aof, both" ;;
esac

# --- resolve the secret ------------------------------------------------------
SECRET=
if [ -n "$IMQ_REQUIREPASS_FILE" ]; then
    [ -r "$IMQ_REQUIREPASS_FILE" ] || die "IMQ_REQUIREPASS_FILE='$IMQ_REQUIREPASS_FILE' is not readable"
    SECRET=$(cat "$IMQ_REQUIREPASS_FILE")
    if [ -n "$IMQ_REQUIREPASS" ] && [ "$IMQ_REQUIREPASS" != "$SECRET" ]; then
        die "IMQ_REQUIREPASS and IMQ_REQUIREPASS_FILE are both set and disagree.
  Set one. IMQ_REQUIREPASS_FILE is preferred: the value stays out of the process
  environment and out of 'docker inspect'."
    fi
elif [ -n "$IMQ_REQUIREPASS" ]; then
    SECRET=$IMQ_REQUIREPASS
fi
case "$SECRET" in
    *[!!-~]*|*' '*) die "the Redis password must not contain whitespace or control characters" ;;
esac

# --- decide the auth / lock mechanism ----------------------------------------
# ACL and the config lock are ONE directive, not two mechanisms: an explicit
# `user default` line overrides requirepass outright, so emitting both hands the
# operator a password that answers WRONGPASS.
case "$IMQ_ACL" in
    auto)
        if [ "$HAS_ACL" = yes ]; then USE_ACL=yes; else
            USE_ACL=no
            note "WARNING: Redis $VER has no ACL, so CONFIG SET and MODULE LOAD stay
  available to every client and the keyspace-event floor can be changed at
  runtime. Authentication still works through requirepass. Set IMQ_ACL=on to
  refuse to start instead of running without the lock."
        fi ;;
    on)
        [ "$HAS_ACL" = yes ] || die "IMQ_ACL=on, but Redis $VER has no ACL support (needs 6.0+).
  Use a newer Redis, or IMQ_ACL=auto to run without the config lock."
        USE_ACL=yes ;;
    off) USE_ACL=no ;;
    *) die "IMQ_ACL='$IMQ_ACL' is not one of: auto, on, off" ;;
esac

# --- scan the remaining CLI arguments ----------------------------------------
# Redis applies command-line options AFTER the config file, so an argument here
# outranks everything composed below. These are the ones that would silently
# undo a guarantee this image claims to make.
BASE_CONF=$IMQ_REDIS_CONF
for arg in "$@"; do
    case "$arg" in
        --notify-keyspace-events)
            die "--notify-keyspace-events on the command line would override the composed
  config and can remove '$FLOOR'. Use IMQ_KEYSPACE_EVENTS, which only adds." ;;
        --user|--aclfile|--rename-command)
            [ "$USE_ACL" = no ] || die "$arg on the command line can restore CONFIG SET to the default user and
  defeat the lock. Set IMQ_ACL=off if you are managing ACLs yourself." ;;
        --maxmemory-policy)
            die "--maxmemory-policy on the command line is refused. An evicting policy lets
  Redis drop queue keys under memory pressure, and messages vanish with no error
  on either side. This image pins 'noeviction'." ;;
        --loadmodule)
            die "--loadmodule on the command line is refused: this image loads exactly one
  announcer, chosen with IMQ_BROKER_MODE. Two loaded announcers double-announce
  the same broker." ;;
    esac
done

# A positional config file, as in `redis-server /etc/mine.conf`, is honoured as
# the base rather than ignored — it is included first, so everything composed
# below still wins.
if [ $# -gt 0 ]; then
    case "$1" in
        -*) ;;
        *) if [ -r "$1" ]; then BASE_CONF=$1; shift; fi ;;
    esac
fi
[ -z "$BASE_CONF" ] || [ -r "$BASE_CONF" ] || die "IMQ_REDIS_CONF='$BASE_CONF' is not readable"

# --- compose -----------------------------------------------------------------
mkdir -p "$(dirname "$CONF")"
: > "$CONF"

{
    cat "$TEMPLATE"

    if [ -n "$BASE_CONF" ]; then
        echo ""
        echo "# --- operator base config, included FIRST so everything below overrides it"
        echo "include $BASE_CONF"
    fi

    echo ""
    echo "# --- persistence: IMQ_PERSISTENCE=$IMQ_PERSISTENCE"
    case "$IMQ_PERSISTENCE" in
        off)  echo 'save ""'; echo "appendonly no" ;;
        rdb)  echo "save 3600 1"; echo "save 300 100"; echo "save 60 10000"; echo "appendonly no" ;;
        aof)  echo 'save ""'; echo "appendonly yes"; echo "appendfsync everysec" ;;
        both) echo "save 3600 1"; echo "save 300 100"; echo "save 60 10000"
              echo "appendonly yes"; echo "appendfsync everysec" ;;
    esac
    if [ "$IMQ_PERSISTENCE" != off ]; then
        # Redis defaults this to yes, which turns a failed bgsave — a full disk, a
        # bad volume permission — into a total refusal of writes while reads keep
        # answering. On a broker that is a producer outage on a queue that still
        # looks alive.
        echo "stop-writes-on-bgsave-error no"
    fi

    if [ "$VER_MAJOR" -ge 7 ]; then
        echo ""
        echo "# --- Redis 7 hardening (these directives do not exist on 6.x, where an"
        echo "#     unknown directive is a FATAL CONFIG FILE ERROR rather than a no-op)"
        echo "enable-module-command no"
        echo "enable-protected-configs no"
        echo "enable-debug-command no"
    fi

    echo ""
    echo "# --- memory"
    [ -z "$IMQ_MAXMEMORY" ] || echo "maxmemory $IMQ_MAXMEMORY"
    echo "maxmemory-policy noeviction"

    echo ""
    echo "# --- authentication and the config lock"
    if [ "$USE_ACL" = yes ]; then
        chan=""
        [ "$HAS_ACL_CHANNELS" = no ] || chan=" &*"
        if [ -n "$SECRET" ]; then cred=">$SECRET"; else cred="nopass"; fi
        # -config +config|get rather than -config|set: subcommand DENIAL is Redis
        # 7.0+, subcommand ALLOW works from 6.0, and deny-then-re-allow is both
        # portable and stricter. CONFIG GET and MODULE LIST stay reachable on
        # purpose — they are how an operator verifies what actually took effect.
        echo "user default on $cred ~*$chan +@all -config +config|get -module +module|list"
    elif [ -n "$SECRET" ]; then
        echo "requirepass $SECRET"
    else
        echo "# no authentication configured — set IMQ_REQUIREPASS_FILE"
    fi

    echo ""
    echo "# --- keyspace events: the floor '$FLOOR' plus IMQ_KEYSPACE_EVENTS, written"
    echo "#     LAST so no included file can defeat it"
    echo "notify-keyspace-events \"$FLAGS\""
} >> "$CONF"

chmod 0444 "$CONF"

if [ "$IMQ_PRINT_CONFIG" != 0 ]; then
    cat "$CONF"
    exit 0
fi

# --- banner ------------------------------------------------------------------
# What actually took effect, so an operator reading logs never has to infer it.
auth_state="off"; [ -z "$SECRET" ] || auth_state="on"
lock_state="off"; [ "$USE_ACL" = no ] || lock_state="on (CONFIG SET, CONFIG REWRITE, MODULE LOAD denied)"
note "redis $VER | mode=$IMQ_BROKER_MODE | keyspace-events=$FLAGS | persistence=$IMQ_PERSISTENCE | auth=$auth_state | config-lock=$lock_state"
[ -n "$SECRET" ] || note "NOTE: no password is set. Every broker in one discovered fleet must share
  the same password, because per-entry cluster credentials are ignored client
  side — see README, 'Authentication'."

# --- hand off ----------------------------------------------------------------
set -- redis-server "$CONF" "$@"
[ "$IMQ_BROKER_MODE" = none ] || set -- "$@" --loadmodule "$MODULE_DIR/$IMQ_BROKER_MODE.so"

exec "$UPSTREAM" "$@"
