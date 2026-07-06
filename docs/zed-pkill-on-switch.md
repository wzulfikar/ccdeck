# Restart Claude ACP on switch (Zed)

When ccdeck switches accounts it rewrites the live Keychain entry
(`Claude Code-credentials`) verbatim — see `Keychain.activate`. That only affects
sessions launched **after** the write. Any already-running `claude` process keeps
using the OAuth token it loaded into memory at startup (the CLI caches its
credential per-process). So a switch mid-chat has no effect on the current
process: the next prompt reuses the old account and, if that account was rate
limited (429), stays rate limited. A 429 is not an auth error, so the process
never re-reads the Keychain on its own.

The "Restart Claude ACP on switch" setting (`AppModel.restartAcpOnSwitch`,
default **off**) closes this gap. On switch it kills the adapter process Zed
spawns to talk to Claude; Zed respawns it on the next prompt, and the fresh
process re-reads the swapped Keychain entry — picking up the new account with no
`claude auth login` dance.

## The process pattern

`restartClaudeAcp()` runs `pkill -f <pattern>`. Getting the pattern right is the
whole trick, because Zed has changed which binary it spawns:

- **Old:** a standalone `claude-code-acp` adapter.
- **Current:** the `@anthropic-ai/claude-agent-sdk` binary, whose path contains
  `claude-agent-sdk` (e.g.
  `…/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude … --output-format
  stream-json …`).

The pattern is therefore `claude-code-acp|claude-agent-sdk` — macOS `pkill`
treats the pattern as an extended regex, and `-f` matches against the full
argument list, so the alternation covers both adapters.

> **Rot warning:** this depends on Zed's binary name. If Zed renames it again the
> pattern silently matches nothing, `pkill` exits 1, and the toggle becomes a
> no-op again with no error surfaced. Verify with
> `pgrep -f "claude-code-acp|claude-agent-sdk"` if switches stop taking effect.
> (This exact regression is why the pattern was widened — the original
> `claude-code-acp`-only pattern matched zero processes after Zed moved to the
> agent SDK.)

## Disruption model

`pkill -f` matches **every** Zed agent-sdk process on the machine, not just the
thread you switched from. Whether that hurts depends on process state:

- **Idle thread** — safe. Zed persists each session to disk
  (`--session-id` / `--resume`), so the respawned process restores history. Worst
  case is a transient reconnect blip.
- **In-flight thread (generating)** — disruptive. SIGTERM aborts the stream
  mid-turn; that turn's output is lost and must be re-prompted.

So the safe rule is not "the chat I switched in is idle" but "**all** Zed threads
are idle" — a different window mid-generation loses its turn too. Targeting only
the rate-limited thread's PID would avoid this, but ccdeck has no mapping from PID
to account, so the blunt pattern kill is the deliberate tradeoff.
