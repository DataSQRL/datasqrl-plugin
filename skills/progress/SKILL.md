---
name: progress
description: Use when the user asks anything about the DataSQRL Code Agent run for the current project: whether it is still running or has finished, how far it has come, or asks to stop it. Works from any session at any time, including one that did not start the run. Explains and reports; does not fix or investigate the project.
argument-hint: "[optional pasted progress lines]"
allowed-tools: Bash, Read
---
Explain the progress of the DataSQRL Code Agent run for the current project.

## How to look

Run this from the project directory and read the output before answering. It prints the last 40 lines of the run's progress trail, then one status line:

```bash
CODEAGENT="${CLAUDE_PLUGIN_ROOT}/scripts/codeagent.sh"
[ -f "$CODEAGENT" ] || CODEAGENT=codeagent.sh   # fall back to PATH
bash "$CODEAGENT" --status 40
```

When the user only asks whether the run is still going or has finished, run `bash "$CODEAGENT" --status` without a count and relay that one line as the whole answer.

If the user pasted lines from their terminal, explain those lines and use the command only to add where the run is now.

## What the lines mean

The trail has one line per event, `+HH:MM:SS  KIND   text`, where the stamp is the time elapsed since the run started. An indented line continues the previous one. The file is written during the run and stays afterwards until the next run overwrites it, so the last run's trail can always be revisited.

- `RUN`: the run started, with its mode (planning, implementation, patch, question).
- `STEP`: a milestone of the orchestrator: `Iteration N · implementing`, `· running tests`, `· verifying`, `· verified (K issue(s), score S)`, `Finalizing`.
- `TEXT`: a sentence the coding agent wrote while working, in full.
- `TOOL`: a tool call, the tool name and its main argument, for example `Bash /opt/agent/cmd.sh test my-package.json` (one compile-and-test run) or `Write /workspace/connectors/sources.sqrl`.
- `TASK`: a subagent the coding agent started, with its description; `↻` marks a progress update of that subagent.
- `THINK`: the first 160 characters of a thought.
- `INFO` and `JUDGE`: other orchestrator messages, for example per-package judge results.
- `WARN`: a recoverable problem, for example `tests failed, retrying`.
- `ERROR`: a failure; `Run stopped (SIGTERM)` means someone stopped the run.
- `DONE`: the end: `Finished · success|failed · mode · scenario · N refinement(s) · K issue(s)`.

## What an iteration is

Iteration 0 implements the plan: the coding agent works through the plan's checklist, compiling and testing as it goes (every `cmd.sh test` line is one compile-and-test run while `cmd.sh compile` is a compile run only). Then the orchestrator runs the tests itself (`running tests`) and, for implementation runs, a panel of LLM judges reviews the result (`verifying`), which ends in `verified (K issues, score S)`. When the score is too high the run enters iteration 1: the agent fixes the reported issues, then tests and judges run again. `Finalizing` is the last gate, README and plan-checklist completeness. Planning and patch runs have no judge panel. An implementation usually takes 30 to 60 minutes; planning and patches take minutes.

## Stuck or working?

`--status` shows the last activity and its age. A few minutes without a new line is normal while a compile, a test suite or a subagent runs (`TASK` lines mark those). Twenty minutes or more without activity while the container is still running is unusual: say so. `No run in progress. Last result: …` means the run has ended.

## Boundaries

Explain what the output means and where the run is. Keep out of the project's source files, `build/` and the plan, leave the implementation unreviewed and unfixed, and end without offering to re-run.

## Stopping a run

Only when the user explicitly asks to stop it:

```bash
bash "$CODEAGENT" --stop
```

It prints `Stopped the run for this project.` or `No run in progress for this project.`; relay that line and stop.
