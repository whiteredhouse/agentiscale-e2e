#!/usr/bin/env bash
# Run a released agentiscaled against the real agentiscale service, end to end,
# as a user would: two fresh nodes join the CI network,
# one offers an agent (Codex, stood in by fake-codex) and the other calls it
# with `agentiscaled task send`, over the mesh's relays.
#
# Each node runs in a container on a Docker network of its own: both reach
# the internet, but not each other, as two machines behind different NATs.
# So the call only gets through over a relay circuit.
#
# Usage: run.sh [VERSION]   (default: the latest release; v0.12.0 or later)
#
# Environment:
#   AGENTISCALE_CI_NETWORK        ID of the CI network. In a GitHub Actions job
#                                 with id-token: write, each node joins with
#                                 its own OIDC token from the job, which the
#                                 network trusts.
#   AGENTISCALE_CI_JOIN_CODE      a join code of the CI network instead, to
#                                 run the check from elsewhere
#   AGENTISCALE_CONTROL           control service (default https://control.agentiscale.net)
#   AGENTISCALE_MESH_DOMAIN       domain the network's mesh must be served under
#                                 (default c1.mesh.agentiscale.net): the check
#                                 fails if the network's mesh is elsewhere
#   NETWORK_CHECK_DIR                where binaries, data and logs go (default: a new temp dir)
#   AGENTISCALE_INSTALL_SH        installer URL (default: https://get.agentiscale.net)
#   NETWORK_CHECK_IMAGE              image the nodes run in (default: Debian slim, pinned)
#   NETWORK_CHECK_NODES              nodes to join, 2 to 20 (default 2): beyond the
#                                 two that call the agent, the rest join on one
#                                 more Docker network and must each connect
#
# Needs Docker, curl and python3. agentiscaled's install.sh fetches the release.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
version=${1:-latest}
control=${AGENTISCALE_CONTROL:-https://control.agentiscale.net}
# Control builds a token's expected audience from its URL without trailing
# slashes, so the audience asked for here must too.
while [ "${control%/}" != "$control" ]; do control=${control%/}; done
mesh_domain=${AGENTISCALE_MESH_DOMAIN:-c1.mesh.agentiscale.net}
nodes=${NETWORK_CHECK_NODES:-2}
if ! [[ "$nodes" =~ ^[0-9]+$ ]] || [ "$nodes" -lt 2 ] || [ "$nodes" -gt 20 ]; then
	echo "NETWORK_CHECK_NODES must be a number from 2 to 20, not '$nodes'" >&2
	exit 1
fi
image=${NETWORK_CHECK_IMAGE:-debian@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc}
if [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${AGENTISCALE_CI_NETWORK:-}" ]; then
	credential=oidc
elif [ -n "${AGENTISCALE_CI_JOIN_CODE:-}" ]; then
	credential="join-code"
else
	echo "set AGENTISCALE_CI_NETWORK in a GitHub Actions job with id-token: write, or AGENTISCALE_CI_JOIN_CODE" >&2
	exit 1
fi
work=${NETWORK_CHECK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/network-check.XXXXXX")}
mkdir -p "$work"
work=$(cd "$work" && pwd)
run_id=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
agent="network-check-agent-$run_id"
nonce="network-check-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"

# The binary runs in Linux containers.
case "$(uname -s)" in
Linux) ;;
*) echo "unsupported platform $(uname -s)/$(uname -m): the nodes run in Linux containers" >&2; exit 1 ;;
esac

# ---- the release, checked against its checksums by agentiscaled's install.sh ----
# The installer users run, as published with the latest release, so the check
# also covers it. AGENTISCALE_INSTALL_SH replaces it, to try another.
install_sh=${AGENTISCALE_INSTALL_SH:-https://get.agentiscale.net}
# `task send` came in v0.12.0 (OIDC joins in v0.11.0).
older() { [ "$(printf '%s\n' v0.12.0 "$1" | sort -V | head -n 1)" != v0.12.0 ]; }
if [ "$version" != latest ] && older "$version"; then
	echo "$version has no task send; the check needs v0.12.0 or later" >&2
	exit 1
fi
curl -sSfL --retry 3 -o "$work/install.sh" "$install_sh"
PATH="$work/bin:$PATH" AGENTISCALE_VERSION=$version AGENTISCALE_INSTALL_DIR="$work/bin" sh "$work/install.sh"
bin="$work/bin/agentiscaled"
version=v$("$bin" version 2>&1 | sed -n 's/^agentiscaled \([0-9][^ ]*\) .*/\1/p' | head -n 1)
if older "$version"; then
	echo "$version has no task send; the check needs v0.12.0 or later" >&2
	exit 1
fi
echo "release: $version, $("$bin" version 2>&1 | head -n 1)"
cp "$here/fake-codex" "$work/bin/codex"

# ---- two fresh nodes, each behind its own network ----
umask 077
# join_flags NAME prints the flags NAME joins with. Each node needs a token of
# its own: the control service takes a token once.
join_flags() {
	if [ "$credential" = oidc ]; then
		curl -sSf -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
			"$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$control/networks/$AGENTISCALE_CI_NETWORK" |
			python3 -I -c 'import json, sys; print(json.load(sys.stdin)["value"])' >"$work/token-$1"
		echo "-oidc-token-path /work/token-$1 -network $AGENTISCALE_CI_NETWORK"
	else
		printf '%s\n' "$AGENTISCALE_CI_JOIN_CODE" >"$work/join-code"
		echo "-join-code-path /work/join-code"
	fi
}
containers=()
networks=()
# Called by the EXIT trap.
# shellcheck disable=SC2329
stop() {
	for c in "${containers[@]}"; do
		docker logs "$c" >"$work/${c#"network-check-$run_id-"}.log" 2>&1 || true
		docker rm -f "$c" >/dev/null 2>&1 || true
	done
	for n in "${networks[@]}"; do docker network rm "$n" >/dev/null 2>&1 || true; done
}
trap stop EXIT

# Inside the containers $work is /work. The node runs as this user, so the
# files it writes stay readable here.
# start_node NAME [NETWORK] [FLAGS...] starts NAME on a Docker network of its
# own, or on NETWORK when given and not empty.
start_node() {
	local name=$1 net=${2:-}
	shift
	if [ $# -gt 0 ]; then shift; fi
	local c="network-check-$run_id-$name" join
	join=$(join_flags "$name")
	mkdir -p "$work/$name/home"
	if [ -z "$net" ]; then
		net=$c
		docker network create "$net" >/dev/null
		networks+=("$net")
	fi
	# $join is split into its flags on purpose.
	# shellcheck disable=SC2086
	docker run -d --name "$c" --network "$net" --user "$(id -u):$(id -g)" \
		-e HOME="/work/$name/home" -v "$work:/work" -v /etc/ssl/certs:/etc/ssl/certs:ro \
		--entrypoint /work/bin/agentiscaled "$image" \
		-data-dir "/work/$name" $join -control "$control" \
		-hostname "$c" -bind-addr "" \
		-listen /ip4/0.0.0.0/udp/4001/quic-v1,/ip4/0.0.0.0/tcp/4001 "$@" >/dev/null
	containers+=("$c")
}

# The agent's own (isolated) Codex configuration needs a sign-in file; the
# stand-in never reads it.
mkdir -p "$work/callee/codex" "$work/agent"
echo '{}' >"$work/callee/codex/auth.json"
start_node callee "" -agent codex -agent-command /work/bin/codex -agent-name "$agent" \
	-agent-dir /work/agent -agent-owner-config=false -agent-dir-instructions=false -agent-dir-skills=false
start_node caller

# More nodes, for a bigger run by hand: all on one more Docker network (the
# host has room for only a few dozen), each joining with its own token.
extras=()
if [ "$nodes" -gt 2 ]; then
	docker network create "network-check-$run_id-extra" >/dev/null
	networks+=("network-check-$run_id-extra")
	for i in $(seq "$((nodes - 2))"); do
		start_node "extra-$i" "network-check-$run_id-extra"
		extras+=("extra-$i")
	done
	echo "started ${#extras[@]} more nodes"
fi

# The nodes must not reach each other directly, or the check would pass
# without the relay: the callee answers on its own TCP port, the caller
# can't open it.
running() { [ "$(docker inspect -f '{{.State.Running}}' "network-check-$run_id-$1")" = true ]; }
exited() {
	echo "$1: the node exited" >&2
	docker logs "network-check-$run_id-$1" 2>&1 | tail -n 40 >&2
	exit 1
}
callee_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "network-check-$run_id-callee")
probe() { docker exec "network-check-$run_id-$1" timeout 5 bash -c "exec 3<>/dev/tcp/$callee_ip/4001" 2>/dev/null; }
for _ in $(seq 60); do
	running callee || exited callee
	probe callee && break
	sleep 1
done
if ! probe callee; then
	echo "the callee never listened on $callee_ip:4001 (did it join?)" >&2
	docker logs "network-check-$run_id-callee" 2>&1 | tail -n 20 >&2
	exit 1
fi
running caller || exited caller
if probe caller; then
	echo "the caller reaches the callee directly; the check would not exercise the relay" >&2
	exit 1
fi
echo "isolated: the caller can't reach the callee at $callee_ip"

# Every extra node must join and connect to the mesh. Its socket answers
# /readyz with 200 once it is connected (released `status` reports only nodes
# set up with `up`, and these start with flags).
connected() {
	[ -S "$work/$1/agentmesh.sock" ] &&
		curl -sSf -o /dev/null --max-time 5 --unix-socket "$work/$1/agentmesh.sock" http://node/readyz 2>/dev/null
}
if [ ${#extras[@]} -gt 0 ]; then
	waiting=("${extras[@]}")
	started=$SECONDS
	while [ ${#waiting[@]} -gt 0 ] && [ $((SECONDS - started)) -lt 180 ]; do
		left=()
		for name in "${waiting[@]}"; do
			running "$name" || exited "$name"
			connected "$name" || left+=("$name")
		done
		waiting=("${left[@]+"${left[@]}"}")
		[ ${#waiting[@]} -eq 0 ] || sleep 2
	done
	if [ ${#waiting[@]} -gt 0 ]; then
		echo "not connected after 180s: ${waiting[*]}" >&2
		for name in "${waiting[@]}"; do
			echo "---- $name (last 20 lines) ----" >&2
			docker logs "network-check-$run_id-$name" 2>&1 | tail -n 20 >&2
		done
		exit 1
	fi
	echo "all ${#extras[@]} more nodes connected in $((SECONDS - started))s"
fi

# ---- call the agent over the relay ----
status=0
# The callee announces its agent shortly after it joins: -wait-agent covers
# that. The task's steps go to the job log, its ID, state and answer to
# task.json.
started=$SECONDS
docker exec "network-check-$run_id-caller" /work/bin/agentiscaled task send -data-dir /work/caller \
	-wait-agent 5m -timeout 5m -json "$agent" "Reply with this nonce: $nonce" >"$work/task.json" || status=$?
if python3 -I "$here/check_answer.py" "$work/task.json" "$nonce" && [ "$status" -eq 0 ]; then
	echo "the agent answered with the nonce in $((SECONDS - started))s"
else
	echo "task send exited with status $status" >&2
	status=1
fi
# The logs, as the checks below read them.
for name in caller callee "${extras[@]+"${extras[@]}"}"; do docker logs "network-check-$run_id-$name" >"$work/$name.log" 2>&1 || true; done

# All nodes must be on the expected mesh.
for name in caller callee "${extras[@]+"${extras[@]}"}"; do
	if ! grep -rqa -- ".$mesh_domain" "$work/$name"; then
		echo "$name: its mesh is not on $mesh_domain" >&2
		status=1
	fi
	if grep -qE "join code accepted|OIDC token accepted" "$work/$name.log"; then
		echo "$name: $(grep -m1 -E 'join code accepted|OIDC token accepted' "$work/$name.log")"
	else
		echo "$name: never joined" >&2
		status=1
	fi
done
if [ "$status" -ne 0 ]; then
	for name in caller callee; do
		echo "---- $name.log (last 40 lines) ----" >&2
		tail -n 40 "$work/$name.log" >&2
	done
fi
exit "$status"
