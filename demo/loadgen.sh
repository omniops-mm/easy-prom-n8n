#!/bin/sh
# Traffic for the demo profile. Posts to the demo webhook every 3 seconds;
# every tenth request fails on purpose so the failure panels have something to
# show. The webhook does not exist until the seed has activated the workflow,
# so early non-200s are expected.

set -eu

TARGET="${LOADGEN_TARGET:-http://n8n-demo:5678}"
OK_PATH=/webhook/demo-echo
MISSING_PATH=/webhook/demo-no-such-workflow

post() {
	curl -s -o /dev/null --max-time 10 -X POST \
		-H 'Content-Type: application/json' -d "$2" "$TARGET$1" || true
}

echo "[loadgen] posting to $TARGET$OK_PATH every 3s"

n=0
while :; do
	n=$((n + 1))
	if [ $((n % 10)) -eq 0 ]; then
		post "$MISSING_PATH" '{"demo":"missing-path"}'
	else
		post "$OK_PATH" "{\"demo\":\"echo\",\"seq\":$n}"
	fi
	sleep 3
done
