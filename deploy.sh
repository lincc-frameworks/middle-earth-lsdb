#!/bin/bash
# Deploy the LSDB websites with no downtime (blue/green).
#
#   ./deploy.sh                 build and deploy now
#   ./deploy.sh --if-changed    only if a website's `production` branch has
#                               moved since the live container was built
#                               (what the lsdb-deploy timer runs)
#   ./deploy.sh --router        rebuild and restart the router as well; only
#                               needed after changing router/, and the one
#                               case with a few seconds of downtime
#   ./deploy.sh --status        what is live
#
# There are two app containers, "blue" and "green", and only one is live.
# A deploy:
#
#   1. asks GitHub which commit each site's `production` branch points at;
#   2. builds an image from exactly those commits and starts it as the idle
#      colour, beside the live container, which keeps serving;
#   3. checks the new container directly on its own port;
#   4. points the router at it with a graceful reload, which lets requests
#      already in progress finish where they started;
#   5. tells the old container to stop once its downloads are done (at most
#      DRAIN_SECONDS, an hour by default) and removes it.
#
# If the build or the checks fail, nothing changes: the live container is
# never touched until the new one has passed.
#
# On a laptop: CONTAINER_ENGINE=docker (dev-startup.sh does this).

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ENGINE="${CONTAINER_ENGINE:-podman}"
DATA_REPO=https://github.com/astronomy-commons/data.lsdb.io
MAIN_REPO=https://github.com/astronomy-commons/lsdb.io
# A branch, a tag, or a full 40-character commit id (to hold a site still).
DATA_SITE_BRANCH="${DATA_SITE_BRANCH:-production}"
MAIN_SITE_BRANCH="${MAIN_SITE_BRANCH:-production}"
DRAIN_SECONDS="${DRAIN_SECONDS:-3600}"
ROUTER=lsdb-router
STATE=/usr/local/apache2/conf/state/backend.conf

log()  { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
die()  { log "FAILED: $*" >&2; exit 1; }
# Every container command runs with the deploy lock (file descriptor 9, taken
# below) closed. Otherwise the long-lived processes podman leaves behind for
# each container inherit it and hold the lock for as long as the container
# lives, and every later deploy finds one "already running".
engine()  { command "$ENGINE" "$@" 9>&-; }
compose() { engine compose "$@"; }
port_of() { case "$1" in blue) echo 8081 ;; green) echo 8082 ;; esac; }
running() { [ "$(engine inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }
exists()  { engine inspect "$1" >/dev/null 2>&1; }

# resolve <repo url> <ref>: print the commit id the ref points at.
resolve() {
    if [[ "$2" =~ ^[0-9a-f]{40}$ ]]; then echo "$2"; return 0; fi
    git ls-remote "$1" "refs/heads/$2" "refs/tags/$2" "refs/tags/$2^{}" 2>/dev/null |
        awk '/\^\{\}$/ { peeled = $1 } NR == 1 { first = $1 }
             END { id = peeled ? peeled : first; if (id) print id; else exit 1 }'
}

# The colour the router sends traffic to, or nothing.
live_colour() {
    running "$ROUTER" || return 0
    engine exec "$ROUTER" sed -n 's/^# live: //p' "$STATE" 2>/dev/null || true
}

# version_in <colour> <site dir>: the commit that container was built from.
version_in() { engine exec "lsdb-app-$1" cat "/srv/$2/VERSION" 2>/dev/null || true; }

# point_router <colour>: make it the live one, without dropping connections.
point_router() {
    printf '%s\n' \
        "# live: $1" \
        "# Written by deploy.sh; do not edit." \
        "ProxyPass        / http://lsdb-app-$1:8080/ disablereuse=On" \
        "ProxyPassReverse / http://lsdb-app-$1:8080/" |
        engine exec -i "$ROUTER" sh -c "cat > $STATE.new && mv $STATE.new $STATE" || return 1
    engine exec "$ROUTER" httpd -t >/dev/null 2>&1 || return 1
    # USR1 is Apache's graceful restart: it rereads its configuration, and
    # each worker finishes the request it is serving before it goes.
    engine kill --signal USR1 "$ROUTER" >/dev/null
}

# get <port> <path> [Host]: body of the response, or nothing.
get() { curl -fsS --max-time 10 ${3:+-H "Host: $3"} "http://127.0.0.1:$1$2" 2>/dev/null || true; }

# check <port> <data commit> <lsdb.io commit>: both sites and /hats/ answer,
# and are the versions expected. Retries for up to 30 seconds.
check() {
    local i why=
    for i in $(seq 1 30); do
        if [ "$(get "$1" /VERSION)" != "$2" ]; then why="data.lsdb.io is not at $2"
        elif [ "$(get "$1" /VERSION lsdb.io)" != "$3" ]; then why="lsdb.io is not at $3"
        elif [ -z "$(get "$1" /)" ]; then why="data.lsdb.io has no front page"
        elif [ -z "$(get "$1" / lsdb.io)" ]; then why="lsdb.io has no front page"
        elif [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$1/hats/")" != 200 ]; then
            why="/hats/ is not answering 200 (is the catalog storage mounted?)"
        else return 0
        fi
        sleep 1
    done
    log "check on port $1: $why"
    return 1
}

# drain <colour>: stop that container once its requests are done, then remove
# it. Runs detached, since it can take as long as the longest download.
drain() {
    local name="lsdb-app-$1" cmd
    cmd="$ENGINE stop -t $DRAIN_SECONDS $name >/dev/null 2>&1; $ENGINE rm -f $name >/dev/null 2>&1"
    if [ -d /run/systemd/system ] && command -v systemd-run >/dev/null 2>&1; then
        systemd-run --quiet --collect --unit "lsdb-drain-$1-$(date +%s)" \
            --description "Drain the old LSDB app container ($1)" sh -c "$cmd" 9>&- && return 0
    fi
    nohup sh -c "$cmd" >/dev/null 2>&1 9>&- &
}

if_changed=0 with_router=0
for arg in "$@"; do
    case "$arg" in
        --if-changed) if_changed=1 ;;
        --router)     with_router=1 ;;
        --status)
            live="$(live_colour)"
            if [ -z "$live" ]; then echo "nothing is live (the router is not running, or has no backend)"; exit 1; fi
            echo "live: $live (container lsdb-app-$live)"
            echo "data.lsdb.io at $(version_in "$live" data.lsdb.io)"
            echo "lsdb.io      at $(version_in "$live" lsdb.io)"
            exit 0 ;;
        *) echo "usage: $0 [--if-changed] [--router] | --status" >&2; exit 2 ;;
    esac
done

# One deploy at a time (the timer and a person can both start one).
if command -v flock >/dev/null 2>&1; then
    exec 9> "/tmp/lsdb-deploy-$(id -u).lock"
    if ! flock -n 9; then
        [ "$if_changed" = 1 ] && exit 0
        die "another deploy is running"
    fi
fi

data_id="$(resolve "$DATA_REPO" "$DATA_SITE_BRANCH")" ||
    die "cannot resolve $DATA_SITE_BRANCH of data.lsdb.io (GitHub unreachable, or no such branch)"
main_id="$(resolve "$MAIN_REPO" "$MAIN_SITE_BRANCH")" ||
    die "cannot resolve $MAIN_SITE_BRANCH of lsdb.io (GitHub unreachable, or no such branch)"

old="$(live_colour)"
if [ -n "$old" ] && ! running "lsdb-app-$old"; then
    log "the router points at $old, but lsdb-app-$old is not running; deploying"
    stale="$old" old=
elif [ "$if_changed" = 1 ] && [ -n "$old" ] &&
     [ "$(version_in "$old" data.lsdb.io)" = "$data_id" ] &&
     [ "$(version_in "$old" lsdb.io)" = "$main_id" ]; then
    exit 0      # up to date; say nothing, this runs every minute
fi
case "${old:-${stale:-green}}" in blue) new=green ;; *) new=blue ;; esac
port="$(port_of "$new")"

log "deploying to $new: data.lsdb.io $data_id, lsdb.io $main_id (live now: ${old:-nothing})"

# ── Build, beside whatever is live ──────────────────────────────────────────
export DATA_SITE_REF="$data_id" MAIN_SITE_REF="$main_id"
compose build "app-$new" || die "the image did not build; ${old:-nothing} is still live"

if exists "lsdb-app-$new"; then
    running "lsdb-app-$new" && log "lsdb-app-$new is still finishing downloads from the last deploy; stopping it"
    engine rm -f "lsdb-app-$new" >/dev/null
fi
compose up -d --no-deps "app-$new" || die "lsdb-app-$new did not start; ${old:-nothing} is still live"

if ! check "$port" "$data_id" "$main_id"; then
    engine logs --tail 30 "lsdb-app-$new" 2>&1 || true
    engine rm -f "lsdb-app-$new" >/dev/null 2>&1 || true
    die "the new container did not pass its checks and was removed; ${old:-nothing} is still live"
fi
log "lsdb-app-$new passed its checks on port $port"

# ── Router and monitor ──────────────────────────────────────────────────────
if [ "$with_router" = 1 ] && exists "$ROUTER"; then
    log "rebuilding the router (a few seconds of downtime)"
    compose build router || die "the router image did not build; nothing was switched"
    engine rm -f "$ROUTER" >/dev/null
fi
if ! running "$ROUTER"; then
    # The setup before the router had one container, lsdb-app, on port 8080.
    if exists lsdb-app; then
        log "removing the pre-router container lsdb-app to free port 8080"
        engine rm -f lsdb-app >/dev/null
    fi
    exists "$ROUTER" && engine rm -f "$ROUTER" >/dev/null
    compose up -d --no-deps router || die "the router did not start"
    for i in $(seq 1 30); do running "$ROUTER" && break; sleep 1; done
fi
running lsdb-service-vm || compose up -d --no-deps monitoring ||
    log "WARNING: the monitoring container did not start"

# ── Switch ──────────────────────────────────────────────────────────────────
point_router "$new" || die "could not point the router at $new"
if ! check 8080 "$data_id" "$main_id"; then
    if [ -n "$old" ]; then
        point_router "$old" || true
        engine rm -f "lsdb-app-$new" >/dev/null 2>&1 || true
        die "the sites did not answer through the router after the switch; switched back to $old"
    fi
    die "the sites do not answer through the router"
fi
log "DEPLOYED: $new is live (data.lsdb.io $data_id, lsdb.io $main_id)"

# ── Retire the old container ────────────────────────────────────────────────
if [ -n "$old" ]; then
    log "lsdb-app-$old will stop when its downloads finish (at most $((DRAIN_SECONDS / 60)) minutes)"
    drain "$old"
elif [ -n "${stale:-}" ] && exists "lsdb-app-$stale"; then
    engine rm -f "lsdb-app-$stale" >/dev/null 2>&1 || true
fi
