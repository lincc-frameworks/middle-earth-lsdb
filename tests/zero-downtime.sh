#!/bin/bash
# Check that a deploy drops nothing: with the service already running
# (./dev-startup.sh), deploy again while
#
#   - a slow download of a large file is in progress, and
#   - both sites are being requested continuously,
#
# then require that the live colour changed, every request got a 200, the
# download arrived whole, and the old container went away once it was done.
#
#   ./dev-startup.sh && tests/zero-downtime.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail() { echo "FAIL: $*" >&2; exit 1; }
live() { CONTAINER_ENGINE=docker ./deploy.sh --status | sed -n 's/^live: \([a-z]*\).*/\1/p'; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp" dev-hats/published/zero-downtime-test.bin' EXIT

before="$(live)"
[ -n "$before" ] || fail "nothing is live; run ./dev-startup.sh first"

# 300 MB at 10 MB/s: a download that is still going when the switch happens.
size=$((300 * 1024 * 1024))
head -c "$size" /dev/zero > dev-hats/published/zero-downtime-test.bin
# Wait until the container sees the whole file (Docker Desktop's file sharing
# can lag behind a write on the host).
for i in $(seq 1 30); do
    seen="$(curl -sI http://localhost:8080/hats/zero-downtime-test.bin | tr -d '\r' | sed -n 's/^[Cc]ontent-[Ll]ength: //p')"
    [ "$seen" = "$size" ] && break
    [ "$i" -lt 30 ] || fail "the test file never appeared at full size (saw ${seen:-nothing})"
    sleep 1
done
curl -s --limit-rate 10M -o "$tmp/download" -w '%{http_code}' \
    http://localhost:8080/hats/zero-downtime-test.bin > "$tmp/download.code" &
download=$!

touch "$tmp/go"
(
    while [ -e "$tmp/go" ]; do
        for host in data.lsdb.io lsdb.io; do
            code="$(curl -s -o /dev/null --max-time 5 -H "Host: $host" -w '%{http_code}' http://localhost:8080/ || true)"
            echo "$host $code" >> "$tmp/requests"
        done
    done
) &
requests=$!
sleep 2

./dev-startup.sh

sleep 2
rm -f "$tmp/go"
wait "$requests"

after="$(live)"
[ "$after" != "$before" ] || fail "the live colour did not change (still $before)"
echo "live colour: $before -> $after"

total="$(wc -l < "$tmp/requests" | tr -d ' ')"
bad="$(grep -c -v ' 200$' "$tmp/requests" || true)"
echo "requests during the deploy: $total, not 200: $bad"
[ "$total" -gt 20 ] || fail "too few requests were made to mean anything"
[ "$bad" = 0 ] || { grep -v ' 200$' "$tmp/requests" | sort | uniq -c >&2; fail "$bad requests failed during the deploy"; }

kill -0 "$download" 2>/dev/null ||
    fail "the download finished before the switch, so this proved nothing; make the file bigger"
docker inspect "lsdb-app-$before" >/dev/null 2>&1 ||
    fail "the old container was removed while a download was still in progress"
wait "$download"
got="$(wc -c < "$tmp/download" | tr -d ' ')"
echo "download across the switch: HTTP $(cat "$tmp/download.code"), $got of $size bytes"
[ "$(cat "$tmp/download.code")" = 200 ] && [ "$got" = "$size" ] || fail "the download was cut short"

for i in $(seq 1 30); do
    docker inspect "lsdb-app-$before" >/dev/null 2>&1 || break
    [ "$i" -lt 30 ] || fail "the old container lsdb-app-$before is still there 30 s after its last download ended"
    sleep 1
done
echo "old container lsdb-app-$before is gone"
echo "zero-downtime check passed"
