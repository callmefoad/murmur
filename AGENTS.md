# Agent instructions

Before working in this repository, read [`AI_HANDOFF.md`](AI_HANDOFF.md) and
inspect the current Git branch, working tree, and recent commits. Treat the
handoff as the shared source of truth for decisions and cross-agent status.

After making changes, append a dated handoff entry with changed files,
verification and exact results, commit/push status, and the next recommended
step. Preserve entries from other agents. Never record secrets or dictation
content. Work serially with Claude: inspect and preserve any uncommitted changes
before editing overlapping files. Do not claim tests passed unless they ran.
