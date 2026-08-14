#!/bin/sh
# Traffic for the demo profile: posts to the demo webhook every 2-5 seconds;
# every tenth request fails on purpose so status panels have variety. Runs in
# a curl image on the compose network; needs no published port.

set -eu

TARGET="${LOADGEN_TARGET:-http://n8n-demo:5678}"
WEBHOOK_PATH="${LOADGEN_WEBHOOK_PATH:-/webhook/demo-echo}"
MISSING_PATH="${LOADGEN_MISSING_PATH:-/webhook/demo-no-such-workflow}"

running=1
sleep_pid=""
sent=0
serving=0
waiting_logged=0

log() {
	echo "[loadgen] $*"
}

# compose stop sends SIGTERM; killing the pending sleep makes the container
# exit now instead of at the end of the pause
on_terminate() {
	running=0
	kill "$sleep_pid" 2>/dev/null || true
}
trap on_terminate TERM INT

# prints the HTTP status; curl prints 000 on connection failure, which this
# loop treats as an answer, not an error
post() {
	curl --silent --output /dev/null --max-time 10 --write-out '%{http_code}' \
		--request POST --header 'Content-Type: application/json' \
		--data "$2" "$TARGET$1" || true
}

# 2-5 seconds, cycled: $RANDOM is not POSIX
nap() {
	sleep "$((2 + (sent * 3) % 4))" &
	sleep_pid=$!
	wait "$sleep_pid" 2>/dev/null || true
	sleep_pid=""
}

log "posting to $TARGET$WEBHOOK_PATH every 2-5 seconds"

while [ "$running" -eq 1 ]; do
	sent=$((sent + 1))
	kind="echo"

	# failures start only once the webhook answers, so the startup race is not
	# counted as demo error traffic
	if [ "$serving" -eq 1 ] && [ $((sent % 10)) -eq 0 ]; then
		if [ $(((sent / 10) % 2)) -eq 0 ]; then
			kind="missing"
		else
			kind="malformed"
		fi
	fi

	case "$kind" in
	missing)
		# no workflow serves this path; n8n answers 404
		status=$(post "$MISSING_PATH" '{"demo":"missing-path"}')
		;;
	malformed)
		# truncated JSON; n8n rejects it before the workflow runs
		status=$(post "$WEBHOOK_PATH" '{"demo":')
		;;
	*)
		status=$(post "$WEBHOOK_PATH" "{\"demo\":\"echo\",\"seq\":$sent}")
		;;
	esac

	if [ "$kind" = "echo" ]; then
		if [ "$status" = "200" ]; then
			if [ "$serving" -eq 0 ]; then
				serving=1
				log "webhook $WEBHOOK_PATH is serving, sending steady traffic"
			fi
		elif [ "$serving" -eq 1 ]; then
			log "unexpected status $status from $WEBHOOK_PATH"
		elif [ "$waiting_logged" -eq 0 ]; then
			# the webhook does not exist until the seed has activated the
			# workflow; say so once, then keep quiet
			waiting_logged=1
			log "webhook $WEBHOOK_PATH not registered yet (status $status), retrying quietly"
		fi
	fi

	nap
done

log "stopped after $sent requests"
