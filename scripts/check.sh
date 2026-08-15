#!/bin/sh
# Validates and tests the stack on this machine.
#
#   ./scripts/check.sh            validate every config, then boot the core
#                                 stack and prove the provisioning loaded (~2 min)
#   ./scripts/check.sh --matrix   also simulate each supported install mode
#                                 with a real n8n (~8 min, pulls images once)
#
# The smoke test exists because Grafana logs a provisioning file it cannot use
# and starts anyway: a wrong datasource uid produces a healthy container and
# an empty Grafana, which no syntax check catches.
#
# Everything runs under throwaway compose project names and is removed
# afterwards, volumes included. Nothing outside those projects is touched.

set -eu

cd "$(dirname "$0")/.."

# Git Bash rewrites container-side paths; turn that off and give docker a
# native host path for mounts (pwd -W is a Git Bash builtin)
case "$(uname -s)" in
	MINGW* | MSYS*) export MSYS_NO_PATHCONV=1; HOSTPWD=$(pwd -W) ;;
	*) HOSTPWD=$(pwd) ;;
esac

VECTOR_IMAGE=timberio/vector:0.57.0-alpine
PROM_IMAGE=prom/prometheus:v3.13.2
N8N_IMAGE=docker.n8n.io/n8nio/n8n:2.35.1

# compose override giving Prometheus a loopback port for this run's
# assertions; *.local.yml is gitignored
PORTS_FILE=compose.check-ports.local.yml

# throwaway values for the ${VAR:?} guards
export GRAFANA_ADMIN_USER=check-admin
export GRAFANA_ADMIN_PASSWORD=check-throwaway-password
export N8N_ENCRYPTION_KEY=check-throwaway-encryption-key
export POSTGRES_PASSWORD=check-throwaway-postgres-password
export N8N_HOST=host-gateway
export N8N_NETWORK=check-external-net

PROJECT=epn8ncheck
AUTH="$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD"
FAILED=0

# A fresh clone ships example target files only, and a job with zero targets
# is absent from the targets API entirely. Perform the setup copy step, and
# undo it afterwards unless a real file already existed.
CREATED_TARGET=0
if [ ! -f prometheus/targets/n8n.yml ]; then
	cp prometheus/targets/n8n.yml.example prometheus/targets/n8n.yml
	CREATED_TARGET=1
fi

say()  { printf '\n== %s\n' "$1"; }
ok()   { printf '   ok  %s\n' "$1"; }
fail() { printf '   FAIL %s\n' "$1"; FAILED=1; }

# retry NAME CMD... - run CMD until it succeeds, RETRY_MAX tries (default 60),
# 2s apart. Always returns 0: under set -e a non-zero return here would abort
# the whole run, so a timeout is recorded through fail() instead.
retry() {
	_name=$1; shift
	_n=0
	until "$@" >/dev/null 2>&1; do
		_n=$((_n + 1))
		if [ "$_n" -ge "${RETRY_MAX:-60}" ]; then fail "$_name (timed out)"; return 0; fi
		sleep 2
	done
	ok "$_name"
}

compose() { docker compose -p "$PROJECT" "$@"; }

cleanup() {
	say "cleanup"
	COMPOSE_PROFILES=demo,logs,queue docker compose -p "$PROJECT" \
		-f compose.yaml -f compose.logs.yaml -f compose.demo-queue.yaml \
		down -v --remove-orphans >/dev/null 2>&1 || true
	docker rm -f epn8ncheck-sim >/dev/null 2>&1 || true
	docker network rm check-external-net >/dev/null 2>&1 || true
	rm -f "$PORTS_FILE"
	if [ "$CREATED_TARGET" = 1 ]; then rm -f prometheus/targets/n8n.yml; fi
}
trap cleanup EXIT

# --- 1. static validation ----------------------------------------------------

say "compose files parse, every shipped combination"
for c in \
	"-f compose.yaml" \
	"-f compose.yaml -f compose.host.yaml" \
	"-f compose.yaml -f compose.external-network.yaml" \
	"-f compose.yaml -f compose.logs.yaml" \
	"-f compose.yaml -f compose.demo-queue.yaml"; do
	# shellcheck disable=SC2086  # $c is a flag list on purpose
	if COMPOSE_PROFILES=demo,logs,queue docker compose $c config -q 2>/dev/null; then
		ok "$c"
	else
		fail "$c"
	fi
done

say "prometheus.yml passes promtool"
if docker run --rm --entrypoint promtool \
	-v "$HOSTPWD/prometheus:/cfg:ro" -w //cfg "$PROM_IMAGE" \
	check config prometheus.yml >/dev/null 2>&1; then
	ok "promtool check config"
else
	fail "promtool check config"
fi

say "vector.yaml passes vector validate"
if docker run --rm --entrypoint vector \
	-v "$HOSTPWD/vector:/etc/vector:ro" "$VECTOR_IMAGE" \
	validate --no-environment /etc/vector/vector.yaml >/dev/null 2>&1; then
	ok "vector validate"
else
	fail "vector validate"
fi

say "dashboard JSON parses"
PY=$(command -v python3 || command -v python || true)
if [ -n "$PY" ]; then
	for f in grafana/dashboards/n8n/*.json; do
		if "$PY" -c "import json,sys;json.load(open(sys.argv[1],encoding='utf-8'))" "$f" 2>/dev/null; then
			ok "$f"
		else
			fail "$f"
		fi
	done
else
	# A broken dashboard also fails its uid assertion in the smoke test below.
	echo "   skip (no python on PATH)"
fi

# --- 2. smoke: boot the core stack, prove the provisioning took effect --------

say "core stack boots"
# Prometheus publishes no port by default; the assertions need its API, so
# this run gets a loopback port through a temporary override.
cat > "$PORTS_FILE" <<'YAML'
services:
  prometheus:
    ports:
      - "127.0.0.1:19090:9090"
YAML
compose -f compose.yaml -f "$PORTS_FILE" up -d --wait --wait-timeout 180 >/dev/null 2>&1 \
	&& ok "up --wait" || fail "up --wait"

g() { curl -fsS -u "$AUTH" "http://127.0.0.1:3000$1"; }

retry "grafana healthy"            sh -c 'curl -fsS http://127.0.0.1:3000/api/health | grep -q "\"database\": *\"ok\""'
retry "datasource uid+type"        sh -c 'curl -fsS -u "'"$AUTH"'" http://127.0.0.1:3000/api/datasources/uid/prometheus | grep -q "\"type\":\"prometheus\""'
for uid in epn8n-overview epn8n-executions epn8n-queue epn8n-http epn8n-internals epn8n-logs; do
	retry "dashboard $uid" sh -c 'curl -fsS -u "'"$AUTH"'" http://127.0.0.1:3000/api/dashboards/uid/'"$uid"' | grep -q "\"uid\":\"'"$uid"'\""'
done
retry "alert rules loaded"         sh -c 'curl -fsS -u "'"$AUTH"'" http://127.0.0.1:3000/api/v1/provisioning/alert-rules | grep -q epn8n'
retry "alert rules health ok"      sh -c '! curl -fsS -u "'"$AUTH"'" http://127.0.0.1:3000/api/prometheus/grafana/api/v1/rules | grep -q "\"health\":\"error\""'
retry "prometheus ready"           curl -fsS http://127.0.0.1:19090/-/ready
retry "n8n scrape job configured"  sh -c 'curl -fsS "http://127.0.0.1:19090/api/v1/targets?state=any" | grep -q "\"scrapePool\":\"n8n\""'

compose -f compose.yaml -f "$PORTS_FILE" down -v >/dev/null 2>&1

[ "${1:-}" = "--matrix" ] || {
	say "done"
	[ "$FAILED" -eq 0 ] && echo "all checks passed" || { echo "CHECKS FAILED"; exit 1; }
	exit 0
}

# --- 3. matrix: simulate each install mode with a real n8n --------------------
# Each scenario sets up n8n the way a user would have it, runs the documented
# install command, and asserts Prometheus reports the target UP.

# PromQL up{job="n8n"} rather than grepping the targets JSON: the value is 1
# only when the last scrape of an n8n target succeeded, and the self-scrape
# cannot satisfy it.
target_up() {
	curl -fsS 'http://127.0.0.1:19090/api/v1/query?query=up%7Bjob%3D%22n8n%22%7D' 2>/dev/null \
		| grep -q ',"1"\]'
}

say "matrix A: demo profile (no existing n8n)"
# no --wait: the seed is a one-shot whose exit is its success, and --wait
# treats an exited service as a failure; the retries below do the waiting
COMPOSE_PROFILES=demo compose -f compose.yaml -f "$PORTS_FILE" up -d >/dev/null 2>&1 \
	&& ok "demo up" || fail "demo up"
retry "demo target UP" target_up
# a fresh demo needs migrations, the seed, the first 30s schedule tick and a
# scrape before this series exists, so this check gets a longer window
RETRY_MAX=150 retry "real execution metrics" sh -c 'curl -fsS "http://127.0.0.1:19090/api/v1/query?query=n8n_workflow_success_total" | grep -q workflow_name'
COMPOSE_PROFILES=demo compose -f compose.yaml -f "$PORTS_FILE" down -v >/dev/null 2>&1 || fail "demo down"

say "matrix B: n8n in its own compose project (external network mode)"
docker network create check-external-net >/dev/null 2>&1 || true
docker run -d --name epn8ncheck-sim --network check-external-net --network-alias n8n \
	-e N8N_METRICS=true "$N8N_IMAGE" >/dev/null 2>&1 \
	&& ok "simulated user n8n up" || fail "simulated user n8n up"
compose -f compose.yaml -f compose.external-network.yaml -f "$PORTS_FILE" up -d --wait --wait-timeout 180 >/dev/null 2>&1 \
	&& ok "stack attached to external network" || fail "stack attached to external network"
retry "external target UP" target_up
compose -f compose.yaml -f compose.external-network.yaml -f "$PORTS_FILE" down -v >/dev/null 2>&1 || fail "external down"
docker rm -f epn8ncheck-sim >/dev/null 2>&1 || true

say "matrix C: n8n reachable via the host (host mode)"
# Simulated by publishing an n8n on the host loopback. host-gateway reaches
# loopback-published ports on Docker Desktop; on bare Linux this scenario
# needs the service on 0.0.0.0 and may report DOWN without the mode being
# broken.
docker run -d --name epn8ncheck-sim -p 127.0.0.1:5678:5678 \
	-e N8N_METRICS=true "$N8N_IMAGE" >/dev/null 2>&1 \
	&& ok "simulated host n8n up" || fail "simulated host n8n up"
compose -f compose.yaml -f compose.host.yaml -f "$PORTS_FILE" up -d --wait --wait-timeout 180 >/dev/null 2>&1 \
	&& ok "stack up with host override" || fail "stack up with host override"
retry "host target UP" target_up
compose -f compose.yaml -f compose.host.yaml -f "$PORTS_FILE" down -v >/dev/null 2>&1 || fail "host down"
docker rm -f epn8ncheck-sim >/dev/null 2>&1 || true

say "done"
[ "$FAILED" -eq 0 ] && echo "all checks passed" || { echo "CHECKS FAILED"; exit 1; }
