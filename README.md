# agentiscale-e2e

End-to-end checks of released [agentiscaled](https://github.com/whiteredhouse/agentiscaled)
builds against the real agentiscale service, run the way users run them.

- [`network/`](network/README.md): two nodes of the latest release join a
  network kept for this check and call an agent between them over a relay,
  daily (`.github/workflows/network.yml`).
