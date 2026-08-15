#!/bin/sh
# doctor.sh - report which n8n metric families an instance exports and name the
# n8n environment variables still missing for the dashboards in this stack.
# Read-only: GET requests to n8n and (optionally) the Prometheus API, nothing
# else. No credentials: n8n's /metrics is unauthenticated by design.
#
# Detection principle: a family's "# TYPE" line appears as soon as its flag is
# read at startup; sample lines appear only once something is measured. TYPE
# line without samples = flag on, no data yet. No TYPE line = flag off. The
# event-bus counters are the exception: created only when their event first
# fires, so absence there is ambiguous and is reported as such.
#
# Usage: doctor.sh [N8N_URL] [PROMETHEUS_URL]

set -u

TIMEOUT=5

# readiness answers 503 while migrations run on a fresh instance (~8s on
# SQLite, longer on Postgres); poll it this long before giving up
READY_WAIT=60

PREFIX=${N8N_METRICS_PREFIX:-n8n_}

# Literal newline, used to build the paste-ready environment block.
NL='
'

usage() {
	cat <<'EOF'
Usage: doctor.sh [N8N_URL] [PROMETHEUS_URL]

  N8N_URL         base URL of the n8n instance   (default http://localhost:5678)
  PROMETHEUS_URL  base URL of Prometheus         (default: skip the scrape check)

Options:
  -h, --help      print this help and exit

Environment:
  N8N_METRICS_PREFIX  metric name prefix configured in n8n (default n8n_)
  NO_COLOR            set to any value to disable coloured output

Examples:
  doctor.sh
  doctor.sh http://n8n.example.com:5678
  doctor.sh http://n8n.example.com:5678 http://localhost:9090

The script only reads. It needs no credentials: the n8n metrics endpoint is
unauthenticated and n8n provides no way to protect it.
EOF
}

case "${1-}" in
-h | --help)
	usage
	exit 0
	;;
esac

N8N_URL=${1:-http://localhost:5678}
PROM_URL=${2-}

# curl treats a bare "host:port/path" ambiguously, so give it an explicit scheme.
case "$N8N_URL" in
*://*) ;;
*) N8N_URL="http://$N8N_URL" ;;
esac
N8N_URL=${N8N_URL%/}

if [ -n "$PROM_URL" ]; then
	case "$PROM_URL" in
	*://*) ;;
	*) PROM_URL="http://$PROM_URL" ;;
	esac
	PROM_URL=${PROM_URL%/}
fi

if [ -t 1 ] && [ -z "${NO_COLOR-}" ]; then
	C_OK=$(printf '\033[32m')
	C_MISS=$(printf '\033[33m')
	C_FAIL=$(printf '\033[31m')
	C_DIM=$(printf '\033[2m')
	C_OFF=$(printf '\033[0m')
else
	C_OK=''
	C_MISS=''
	C_FAIL=''
	C_DIM=''
	C_OFF=''
fi

if ! command -v curl >/dev/null 2>&1; then
	printf '%s\n' "curl is required and was not found in PATH." >&2
	exit 1
fi

WORKDIR=$(mktemp -d 2>/dev/null || mktemp -d -t epn8n) || {
	printf '%s\n' "Could not create a temporary directory." >&2
	exit 1
}
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

METRICS_FILE="$WORKDIR/metrics.txt"
CURL_ERR="$WORKDIR/curl.err"

line_ok() { printf '%s[ OK ]%s %-30s %s\n' "$C_OK" "$C_OFF" "$1" "$2"; }
line_idle() { printf '%s[IDLE]%s %-30s %s\n' "$C_DIM" "$C_OFF" "$1" "$2"; }
line_miss() { printf '%s[MISS]%s %-30s %s\n' "$C_MISS" "$C_OFF" "$1" "$2"; }
line_open() { printf '%s[ ?? ]%s %-30s %s\n' "$C_MISS" "$C_OFF" "$1" "$2"; }
line_warn() { printf '%s[WARN]%s %s\n' "$C_MISS" "$C_OFF" "$1"; }
line_fail() { printf '%s[FAIL]%s %s\n' "$C_FAIL" "$C_OFF" "$1"; }
line_info() { printf '%s[INFO]%s %s\n' "$C_DIM" "$C_OFF" "$1"; }
line_hint() { printf '       %s%s%s\n' "$C_DIM" "$1" "$C_OFF"; }
heading() { printf '\n%s\n' "$1"; }

# Writes the response body to $2 and prints the HTTP status code. The curl exit
# status is returned so that a transport failure can be told from an HTTP error.
fetch() {
	curl -sS -o "$2" -w '%{http_code}' --max-time "$TIMEOUT" "$1" 2>"$CURL_ERR"
}

curl_reason() {
	case "$1" in
	6) printf '%s' "the host name could not be resolved" ;;
	7) printf '%s' "the connection was refused or there is no route to the host" ;;
	28) printf '%s' "the request timed out after ${TIMEOUT}s" ;;
	35 | 60) printf '%s' "the TLS handshake or certificate check failed" ;;
	*)
		reason=$(sed -n '1p' "$CURL_ERR")
		[ -n "$reason" ] || reason="curl exit status $1"
		printf '%s' "$reason"
		;;
	esac
}

DATA_KEYS=''
IDLE_KEYS=''
# families whose absence the exposition cannot explain: either the flag is off
# or the thing has simply not happened. Reported as [ ?? ], never as missing.
OPEN_KEYS=''
MISSING_ENV=''
FAMILIES_TOTAL=0
FAMILIES_ENABLED=0
EVENT_BUS_OPEN=0
QUEUE_OPEN=0

# is_open KEY - true when the family's absence has no single explanation.
is_open() {
	case " $OPEN_KEYS " in
	*" $1 "*) return 0 ;;
	esac
	return 1
}

# has KEY - true when the family carries samples.
has() {
	case " $DATA_KEYS " in
	*" $1 "*) return 0 ;;
	esac
	return 1
}

# enabled KEY - true when the family is registered, with or without samples.
enabled() {
	if has "$1"; then
		return 0
	fi
	case " $IDLE_KEYS " in
	*" $1 "*) return 0 ;;
	esac
	return 1
}

# declared NAME_RE - true when the exposition carries a "# TYPE" line for the
# family: the flag test, independent of traffic. The [a-z_]* fragment covers
# prefix-named families (n8n_scaling_mode_queue_jobs_waiting/_active etc.), which
# a whitespace anchor would wrongly report as missing.
declared() {
	grep -Eq "^# TYPE ${1}[a-z_]*[[:space:]]" "$METRICS_FILE"
}

# populated NAME_RE - true when the family carries at least one sample line.
# The fragment also covers the _bucket/_sum/_count series a histogram expands
# into.
populated() {
	grep -Eq "^${1}[a-z_]*[{[:space:]]" "$METRICS_FILE"
}

# check_family KEY LABEL NAME_RE ENV_VAR DASHBOARD KIND
# KIND is "lazy" for the event-bus counters, which n8n does not register until
# their event first fires, "queuemode" for the families that exist only under
# EXECUTIONS_MODE=queue, and "declared" for every family that appears as soon
# as its flag is read.
check_family() {
	FAMILIES_TOTAL=$((FAMILIES_TOTAL + 1))
	if populated "$3"; then
		FAMILIES_ENABLED=$((FAMILIES_ENABLED + 1))
		DATA_KEYS="$DATA_KEYS $1"
		line_ok "$2" "$5"
	elif declared "$3"; then
		FAMILIES_ENABLED=$((FAMILIES_ENABLED + 1))
		IDLE_KEYS="$IDLE_KEYS $1"
		line_idle "$2" "enabled, nothing measured yet"
	elif [ "$4" = "-" ]; then
		line_miss "$2" "no flag adds this"
		line_hint "expected a family named ${PREFIX}version_info; check N8N_METRICS_PREFIX"
	elif [ "$6" = "lazy" ]; then
		line_open "$2" "not registered yet"
		OPEN_KEYS="$OPEN_KEYS $1"
		EVENT_BUS_OPEN=1
	elif [ "$6" = "queuemode" ]; then
		# Absent on a single-process instance no matter how the flag is set, and
		# nothing in the exposition says which mode n8n runs in. Reporting this
		# as a missing flag would tell most users to add one that changes
		# nothing, so it stays out of the paste-ready block.
		line_open "$2" "queue mode only"
		OPEN_KEYS="$OPEN_KEYS $1"
		QUEUE_OPEN=1
	else
		line_miss "$2" "$4=true"
		MISSING_ENV="${MISSING_ENV}${4}=true${NL}"
	fi
}

# check_label KEY LABEL BASE_RE LABELLED_RE ENV_VAR
# A label can only be seen on a sample line, so the verdict is definitive only
# once the family it attaches to carries samples.
check_label() {
	FAMILIES_TOTAL=$((FAMILIES_TOTAL + 1))
	if grep -Eq "$4" "$METRICS_FILE"; then
		FAMILIES_ENABLED=$((FAMILIES_ENABLED + 1))
		DATA_KEYS="$DATA_KEYS $1"
		line_ok "$2" "present on the samples"
	elif grep -Eq "$3" "$METRICS_FILE"; then
		line_miss "$2" "$5=true"
		MISSING_ENV="${MISSING_ENV}${5}=true${NL}"
	else
		line_open "$2" "no samples to read it from yet"
		OPEN_KEYS="$OPEN_KEYS $1"
		EVENT_BUS_OPEN=1
	fi
}

printf '%s\n' "EasyPromN8N doctor"
printf '%s\n' "n8n:        $N8N_URL"
if [ -n "$PROM_URL" ]; then
	printf '%s\n' "prometheus: $PROM_URL"
fi
printf '%s\n' "prefix:     $PREFIX"

# --- Step 1: is n8n reachable at all -----------------------------------------
heading "Step 1: reachability"
CODE=$(fetch "$N8N_URL/healthz" "$WORKDIR/healthz.txt")
RC=$?

if [ "$RC" -ne 0 ]; then
	line_fail "Cannot reach $N8N_URL/healthz: $(curl_reason "$RC")."
	line_hint "Check that n8n is running, that the port is correct, and that it"
	line_hint "listens on an address this machine can reach."
	exit 1
fi

case "$CODE" in
200)
	line_ok "n8n process alive" "HTTP 200 on /healthz"
	line_hint "/healthz answers ok as soon as n8n binds its port. It says nothing about"
	line_hint "the database, the migrations or whether a workflow can run, and it can"
	line_hint "only fail if the process is dead. Readiness below is the real check."
	;;
404)
	line_fail "/healthz returned HTTP 404."
	line_hint "The health endpoint root is configurable through N8N_ENDPOINT_HEALTH,"
	line_hint "and very old n8n versions do not expose it. Confirm the URL and version."
	exit 1
	;;
*)
	line_fail "/healthz returned HTTP $CODE."
	line_hint "A redirect or an error here usually means a reverse proxy sits in front"
	line_hint "of n8n. Point the script at the address n8n itself listens on."
	exit 1
	;;
esac

# --- Step 2: is n8n ready to serve --------------------------------------------
heading "Step 2: readiness"
CODE=$(fetch "$N8N_URL/healthz/readiness" "$WORKDIR/readiness.txt")
RC=$?

WAITED=0
while [ "$RC" -eq 0 ] && [ "$CODE" = "503" ] && [ "$WAITED" -lt "$READY_WAIT" ]; do
	if [ "$WAITED" -eq 0 ]; then
		line_info "/healthz/readiness returned HTTP 503. n8n opens its port before it runs"
		line_hint "database migrations, so this is the expected answer from an instance that"
		line_hint "started seconds ago. Waiting up to ${READY_WAIT}s for it to finish."
	fi
	sleep 3
	WAITED=$((WAITED + 3))
	CODE=$(fetch "$N8N_URL/healthz/readiness" "$WORKDIR/readiness.txt")
	RC=$?
done

if [ "$RC" -ne 0 ]; then
	line_warn "Cannot reach /healthz/readiness: $(curl_reason "$RC")."
elif [ "$CODE" = "200" ]; then
	if [ "$WAITED" -gt 0 ]; then
		line_ok "n8n ready" "database connected and migrated after ${WAITED}s"
	else
		line_ok "n8n ready" "database connected and migrated"
	fi
elif [ "$CODE" = "503" ]; then
	line_warn "/healthz/readiness still returns HTTP 503 after ${WAITED}s."
	line_hint "Readiness is exactly: database connected, migrations applied, startup"
	line_hint "finished. It does not depend on an owner account or on any workflow"
	line_hint "existing, so this is not a sign of an unconfigured instance. Read the"
	line_hint "n8n log: a migration still in progress prints \"Migrations in progress\","
	line_hint "and anything else here means the database is unreachable or failing."
	line_hint "Metrics below may be incomplete until readiness succeeds."
else
	line_warn "/healthz/readiness returned HTTP $CODE."
	line_hint "Anything other than 200 or 503 means the request did not reach n8n."
fi

# --- Step 3: fetch the metrics once -------------------------------------------
heading "Step 3: metrics endpoint"
CODE=$(fetch "$N8N_URL/metrics" "$METRICS_FILE")
RC=$?

if [ "$RC" -ne 0 ]; then
	line_fail "Cannot reach $N8N_URL/metrics: $(curl_reason "$RC")."
	exit 1
fi

case "$CODE" in
200) ;;
404)
	line_fail "/metrics returned HTTP 404: the metrics endpoint is disabled."
	line_hint "Set N8N_METRICS=true on the n8n service and restart it. Nothing else"
	line_hint "can be checked until the endpoint exists."
	printf '\n%s\n\n' "Add this to the n8n service environment and restart n8n:"
	printf '%s\n' "N8N_METRICS=true"
	exit 1
	;;
401 | 403)
	line_fail "/metrics returned HTTP $CODE."
	line_hint "n8n does not authenticate this endpoint, so the rejection comes from a"
	line_hint "proxy in front of it. Scrape n8n directly instead."
	exit 1
	;;
*)
	line_fail "/metrics returned HTTP $CODE."
	exit 1
	;;
esac

DECLARED_COUNT=$(grep -c '^# TYPE ' "$METRICS_FILE")
SAMPLE_COUNT=$(grep -c '^[a-zA-Z]' "$METRICS_FILE")
line_ok "metrics endpoint up" "$DECLARED_COUNT families, $SAMPLE_COUNT samples"
line_hint "This endpoint is unauthenticated and n8n offers no way to protect it."
line_hint "Keep it on a trusted network."

# --- Step 4: which metric families are present --------------------------------
heading "Step 4: metric families"

check_family core "core metrics" \
	"${PREFIX}version_info" \
	"-" "Overview (epn8n-overview)" declared
check_family process "default process metrics" \
	"${PREFIX}nodejs_eventloop_lag_seconds" \
	"N8N_METRICS_INCLUDE_DEFAULT_METRICS" "Overview (epn8n-overview)" declared
check_family duration "execution duration histogram" \
	"${PREFIX}workflow_execution_duration_seconds" \
	"N8N_METRICS_INCLUDE_WORKFLOW_EXECUTION_DURATION" "Overview, Executions" declared
check_family stats "workflow statistics totals" \
	"${PREFIX}(production_executions|workflows|users|credentials)" \
	"N8N_METRICS_INCLUDE_WORKFLOW_STATISTICS" "Overview (epn8n-overview)" declared
check_family eventbus "workflow event counters" \
	"${PREFIX}workflow_(started|success|failed)_total" \
	"N8N_METRICS_INCLUDE_MESSAGE_EVENT_BUS_METRICS" "Executions (epn8n-executions)" lazy
check_family nodeevents "node event counters" \
	"${PREFIX}node_(started|finished)_total" \
	"N8N_METRICS_INCLUDE_MESSAGE_EVENT_BUS_METRICS" "Executions (epn8n-executions)" lazy
check_family jobevents "queue job counters" \
	"${PREFIX}queue_job_(enqueued|dequeued|completed|failed)_total" \
	"N8N_METRICS_INCLUDE_MESSAGE_EVENT_BUS_METRICS" "Queue (epn8n-queue)" lazy
check_family wfinfo "workflow id-to-name map" \
	"${PREFIX}workflow_info" \
	"N8N_METRICS_INCLUDE_WORKFLOW_INFO" "Executions (epn8n-executions)" declared
check_family queue "queue depth gauges" \
	"${PREFIX}scaling_mode_queue_jobs_" \
	"N8N_METRICS_INCLUDE_QUEUE_METRICS" "Queue (epn8n-queue)" queuemode
check_family webhook "webhook latency" \
	"${PREFIX}webhook_request_duration_seconds" \
	"N8N_METRICS_INCLUDE_WEBHOOK_METRICS" "HTTP (epn8n-http)" declared
check_family form "form submission latency" \
	"${PREFIX}form_submission_duration_seconds" \
	"N8N_METRICS_INCLUDE_FORM_METRICS" "HTTP (epn8n-http)" declared
check_family api "api endpoint latency" \
	"${PREFIX}http_request_duration_seconds" \
	"N8N_METRICS_INCLUDE_API_ENDPOINTS" "HTTP (epn8n-http)" declared
check_family cache "cache metrics" \
	"${PREFIX}cache_(hits|misses|updates)_total" \
	"N8N_METRICS_INCLUDE_CACHE_METRICS" "Internals (epn8n-internals)" declared
check_family dbpool "database pool metrics" \
	"${PREFIX}db_pool_connections_" \
	"N8N_METRICS_INCLUDE_DB_POOL_METRICS" "Internals (epn8n-internals)" declared
check_family scheduler "scheduler metrics" \
	"${PREFIX}scheduler_(tasks_dispatched_total|tasks_pending|dispatch_lag_seconds)" \
	"N8N_METRICS_INCLUDE_SCHEDULER_METRICS" "Internals (epn8n-internals)" declared
check_family execdata "execution data io" \
	"${PREFIX}execution_data_(reads_total|writes_total|write_bytes_total)" \
	"N8N_METRICS_INCLUDE_EXECUTION_DATA_METRICS" "Internals (epn8n-internals)" declared

# The label flags are read from the sample lines of the families they attach to.
# workflow_id rides on the duration histogram as well as on the event counters,
# so either source answers the question; node_type exists only on the event
# counters.
check_label wfid "workflow id label" \
	"^${PREFIX}(workflow_execution_duration_seconds_(bucket|sum|count)|workflow_(started|success|failed)_total)[{]" \
	"^${PREFIX}(workflow_execution_duration_seconds_(bucket|sum|count)|workflow_(started|success|failed)_total)[{][^}]*workflow_id=" \
	"N8N_METRICS_INCLUDE_WORKFLOW_ID_LABEL"
check_label nodetype "node type label" \
	"^${PREFIX}node_(started|finished)_total[{]" \
	"^${PREFIX}node_(started|finished)_total[{][^}]*node_type=" \
	"N8N_METRICS_INCLUDE_NODE_TYPE_LABEL"

if [ "$EVENT_BUS_OPEN" -eq 1 ]; then
	printf '\n'
	line_info "A [ ?? ] line means the answer cannot be read from this exposition. The"
	line_hint "counters behind those lines come from the n8n event bus, and n8n creates"
	line_hint "each one the first time its event fires: before that the name is absent"
	line_hint "entirely, with no # HELP and no # TYPE line. So an absent counter means"
	line_hint "either that the flag is off or that no workflow, node or queue job event"
	line_hint "has happened since n8n started, and nothing in the output distinguishes"
	line_hint "them. Run one workflow, then run this script again. If the counters are"
	line_hint "still absent, the flag is the remaining explanation."
fi

if [ "$QUEUE_OPEN" -eq 1 ]; then
	printf '\n'
	line_info "The queue depth gauges exist only when n8n runs in queue mode"
	line_hint "(EXECUTIONS_MODE=queue) and are collected on main instances, never on"
	line_hint "workers. On a single-process instance they are absent no matter how"
	line_hint "N8N_METRICS_INCLUDE_QUEUE_METRICS is set, so this is only worth acting"
	line_hint "on if you do run queue mode; then add the flag to the main instance."
fi

if grep -Eq "^${PREFIX}http_request_duration_seconds_(bucket|sum|count)[{][^}]*path=" "$METRICS_FILE"; then
	printf '\n'
	line_warn "N8N_METRICS_INCLUDE_API_PATH_LABEL is on. Turn it off."
	line_hint "The path label carries the raw request URL, workflow ids included, so"
	line_hint "every workflow touched through the API mints a new 17-bucket histogram"
	line_hint "and the ids end up readable in Prometheus. The series count grows with"
	line_hint "traffic and never falls back. Nothing in this stack needs the label."
fi

# --- Step 5: is Prometheus actually scraping n8n ------------------------------
heading "Step 5: Prometheus scrape target"
if [ -z "$PROM_URL" ]; then
	line_info "No Prometheus URL given. Pass one as the second argument to check it."
else
	# query API rather than /api/v1/targets: one value per response, no JSON
	# structure assumptions needed
	prom_scalar() {
		if ! fetch "$PROM_URL/api/v1/query?query=$1" "$WORKDIR/query.json" >/dev/null; then
			return 1
		fi
		sed -n 's/.*"value":\[[0-9.]*,"\([^"]*\)".*/\1/p' "$WORKDIR/query.json"
	}

	CODE=$(fetch "$PROM_URL/-/ready" "$WORKDIR/ready.txt")
	RC=$?
	if [ "$RC" -ne 0 ]; then
		line_warn "Cannot reach $PROM_URL: $(curl_reason "$RC")."
	elif [ "$CODE" != "200" ]; then
		line_warn "$PROM_URL/-/ready returned HTTP $CODE."
		line_hint "Prometheus answers 503 here while it replays its write-ahead log after"
		line_hint "a restart, which on a large database takes minutes. Try again."
	else
		TARGET_TOTAL=$(prom_scalar 'count(up%7Bjob%3D%22n8n%22%7D)')
		TARGET_UP=$(prom_scalar 'sum(up%7Bjob%3D%22n8n%22%7D)')
		[ -n "$TARGET_TOTAL" ] || TARGET_TOTAL=0
		[ -n "$TARGET_UP" ] || TARGET_UP=0

		if [ "$TARGET_TOTAL" = "0" ]; then
			line_fail "Prometheus knows no target in job \"n8n\"."
			line_hint "Add the instance to prometheus/targets/n8n.yml. Prometheus reloads"
			line_hint "that file on its own, no restart needed."
		elif [ "$TARGET_UP" = "$TARGET_TOTAL" ]; then
			line_ok "scrape target up" "$TARGET_UP/$TARGET_TOTAL in job \"n8n\""
		else
			line_fail "$TARGET_UP of $TARGET_TOTAL targets in job \"n8n\" are up."
			# lastError is empty on a healthy target, so non-empty = the failures;
			# jq adds the address, the grep fallback still names the cause
			if fetch "$PROM_URL/api/v1/targets?state=active&scrapePool=n8n" \
				"$WORKDIR/targets.json" >/dev/null; then
				if command -v jq >/dev/null 2>&1; then
					jq -r '.data.activeTargets[] | select(.health != "up")
					       | "       \(.scrapeUrl) -> \(.lastError)"' \
						"$WORKDIR/targets.json"
				else
					grep -o '"lastError":"[^"]\{1,\}"' "$WORKDIR/targets.json" |
						sed 's/^"lastError":"/       /; s/"$//'
				fi
			fi
			line_hint "Check, in this order:"
			line_hint "  1. n8n binds 0.0.0.0, not 127.0.0.1 (N8N_LISTEN_ADDRESS=0.0.0.0)."
			line_hint "  2. The address in prometheus/targets/n8n.yml is reachable from the"
			line_hint "     Prometheus container, which is not the same as from your shell."
			line_hint "  3. No firewall rule blocks the port between container and host."
			line_hint "  4. The port is the one n8n serves, 5678 unless N8N_PORT changed it."
		fi
	fi
fi

# --- Summary ------------------------------------------------------------------
heading "Summary"
printf '%s\n' "$FAMILIES_ENABLED of $FAMILIES_TOTAL metric families and labels enabled."
printf '\n'

dashboard_line() {
	dash_name=$1
	shift
	dash_missing=0
	dash_idle=0
	dash_open=0
	for dash_key in "$@"; do
		if has "$dash_key"; then
			continue
		elif enabled "$dash_key"; then
			dash_idle=$((dash_idle + 1))
		elif is_open "$dash_key"; then
			dash_open=$((dash_open + 1))
		else
			dash_missing=$((dash_missing + 1))
		fi
	done
	if [ "$dash_missing" -gt 0 ]; then
		line_miss "$dash_name" "$dash_missing panel group(s) have no metric to read"
	elif [ "$dash_open" -gt 0 ]; then
		line_open "$dash_name" "$dash_open panel group(s) cannot be judged from here"
	elif [ "$dash_idle" -gt 0 ]; then
		line_idle "$dash_name" "$dash_idle panel group(s) fill on the first execution"
	else
		line_ok "$dash_name" "fully populated"
	fi
}

dashboard_line "Overview (epn8n-overview)" core process duration stats
dashboard_line "Executions (epn8n-executions)" duration eventbus wfid wfinfo nodetype
dashboard_line "Queue (epn8n-queue)" queue jobevents
dashboard_line "HTTP (epn8n-http)" webhook form api
dashboard_line "Internals (epn8n-internals)" cache dbpool scheduler execdata
line_info "Logs (epn8n-logs) reads from Loki and does not depend on these flags."

if [ -n "$MISSING_ENV" ]; then
	printf '\n%s\n\n' "Add these to the n8n service environment and restart n8n:"
	printf '%s' "$MISSING_ENV"
fi

if has core && enabled process; then
	printf '\n%s\n' "The Overview dashboard has what it needs."
	exit 0
fi

printf '\n%s\n' "The Overview dashboard is missing metrics it needs. See the lines above."
exit 1
