# Real network check

`run.sh` checks the latest `agentiscaled` release (or the one given) against
the real service, the way a user meets it: two fresh nodes join a network
kept for this check through the public control service, one offers an agent
and the other calls it with `agentiscaled task send`, which finds the agent on
the network and follows the task to its end. The agent runs Codex, stood in
by `fake-codex`, which answers with the nonce it was sent, so no model or
sign-in is needed. The check fails unless the answer comes back and both
nodes' mesh is under `AGENTISCALE_MESH_DOMAIN` (default
`c1.mesh.agentiscale.net`).

Each node runs in a Docker container on a network of its own: both reach the
internet but not each other, like two machines behind different NATs, so the
call only gets through over a relay circuit. Before the call the script
checks that the caller can't open the callee's port, so the check can't pass
over a direct connection.

`.github/workflows/network.yml` runs it daily and on demand (with a version,
v0.12.0 or later), from main only, in the `network-check` environment. Then
its `action` job joins one more node with the GitHub Action users join with
([whiteredhouse/agentiscale-action](https://github.com/whiteredhouse/agentiscale-action),
pinned by commit) and checks that it is connected. No secret is stored: each node joins with
its own OIDC token, which the network trusts for this workflow only. Joined
nodes are removed when the trust's node lifetime ends. Pull requests that
change this folder run only the parts that need no network:
`test_parts.py` checks `fake-codex` and `check_answer.py`, which reads the
task's answer.

## Setup (once)

1. Sign in to the console with an account kept for CI. A new account's
   network is created on the default shared mesh.
2. In that account, under **Settings > Trusted workloads**, trust a GitHub
   Actions workflow: repository `whiteredhouse/agentiscale-e2e`, workflow
   `.github/workflows/network.yml`, branch `main`, environment
   `network-check`, events schedule and workflow_dispatch. A run joins 3
   nodes, and each counts against the trust's cap until its lifetime ends,
   even after the run. Set a node lifetime of 15 minutes (a run takes under
   10) and a cap of 6 nodes, so a re-run right after a run still has room.
3. In the repository settings, create the environment `network-check` with
   deployment branches limited to `main`, and set its variable
   `AGENTISCALE_CI_NETWORK` to the network's ID (the console shows it under
   the network's name). It's an ID, not a credential. Set
   `AGENTISCALE_MESH_DOMAIN` too if the network's mesh is elsewhere.

A trust can't be edited. To change its lifetime or cap, revoke it in the
console and create it again with the same fields.

GitHub turns off scheduled workflows in a repository with no commits for 60
days. If that happens, turn it back on under **Actions**.

## A bigger run by hand

Start the workflow by hand with `nodes` above 2 (up to 20) to join that many
nodes from one runner. The rest join on one more Docker network, each with
its own token, and must all connect within 3 minutes. The action job is
skipped on such a run. First make sure the trust's cap has room for all of
them.

## Elsewhere

Without a GitHub token, the script joins with a join code of the network
instead:

```sh
AGENTISCALE_CI_JOIN_CODE=... bash network/run.sh   # needs Docker (Linux)
python3 -I network/test_parts.py                   # no network, no Docker
```

Nodes that join with a join code stay in the member list as offline members
(`network-check-<run>-caller` / `-callee`); remove them from the console.
