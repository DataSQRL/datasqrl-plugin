---
name: status
description: Use when the user asks how a DataSQRL run is going, whether it has finished, what happened to it, or asks to stop it. Reports the DataSQRL Code Agent run for the current project - whether one is in flight and what it is doing, or the last run's result. Works from any session at any time, including one that did not start the run.
argument-hint: ""
allowed-tools: Bash
---
Report the state of the DataSQRL Code Agent run for the current project.

Runs are detached and owned by the Docker daemon, so this works from any session at any time — including a session that did not start the run, and one opened long after it began.

**Working directory**: run `codeagent.sh` in the project directory — the one containing the `adr` subfolder and the project implementation files. Status is keyed to that directory and reports the run for that project.

```bash
CODEAGENT="${CLAUDE_PLUGIN_ROOT}/scripts/codeagent.sh"
[ -f "$CODEAGENT" ] || CODEAGENT=codeagent.sh   # fall back to PATH
bash "$CODEAGENT" --status
```

The command prints exactly one line. Relaying that line is the entire deliverable: relay it and end the turn. It is one of:

- `Running · <mode> · started <n>m ago · <latest milestone>` — a run is in flight.
- `No run in progress. Last result: …` — nothing running; that is the previous run's outcome.
- `No run in progress for this project, and no previous result.` — nothing has run here yet.

## Stopping a run

Only when the user explicitly asks to stop it:

```bash
bash "$CODEAGENT" --stop
```
