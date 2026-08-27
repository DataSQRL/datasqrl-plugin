---
name: implement
description: Use when the user has reviewed a DataSQRL plan and explicitly approved implementing it - for example by saying it looks good, to go ahead, or to implement it. Runs the DataSQRL Code Agent in implementation mode over that plan, the full autonomous implement, compile, test, verify and refine loop.
argument-hint: "[optional path to a plan_*.md]"
allowed-tools: Bash, Monitor, Read
---
Run the DataSQRL Code Agent in **implementation** mode (implement → compile → test → verify → refine) on the current project.

**Working directory**: run `codeagent.sh` in the project directory — the one containing the `adr` subfolder and the project implementation files. The command mounts the entire repository for the agent to read, and the invocation directory is the only one it writes to. `adr/plan_*.md` is discovered relative to that directory.

## Step 1 — start the run

The launch command starts a detached container and returns in about two seconds, printing the run name. Launch once, in the foreground, with the default timeout. The container is owned by the Docker daemon and keeps running after this session is interrupted or closed.

```bash
CODEAGENT="${CLAUDE_PLUGIN_ROOT}/scripts/codeagent.sh"
[ -f "$CODEAGENT" ] || CODEAGENT=codeagent.sh   # fall back to PATH

bash "$CODEAGENT" "$ARGUMENTS" --mode implementation --detach
```

- **Run the first two lines exactly as written.** They locate the launche (`codeagent.sh`).
- With no argument the launcher auto-discovers the latest `adr/plan_*.md`. Pass a path to target a specific plan.
- The printed run name confirms the container **started**. Completion is signalled by the terminal event in step 2.
- A non-zero exit means the run never started — failed preflight (Docker down, image missing, no credential), or a run already in progress for this project. Report that message verbatim and end the turn.

## Step 2 — watch it

If your agent can watch a background command (Claude Code: the `Monitor` tool, `persistent: true`),
watch:

```bash
bash "$CODEAGENT" --watch
```

It prints one short progress line per milestone and exits on its own at a terminal state, so the watcher ends itself — do not set a timeout or stop it early.

If your agent has no such facility, say the run is underway and can be checked with the [`status` skill](../status/SKILL.md).

Either way: tell the user in one sentence that the run is underway and that they can close this session without stopping it, then end your turn. The container keeps working while this sessio sits idle.

## Step 3 — when the run finishes

The last event is terminal (`Finished · …` or `Error · …`). Read `.code_agent_results.json` and report success, mode, scenario, refinements, and issue score/count. If the file is absent, quote the last event instead.
That report is the complete deliverable, for every outcome. Stop after the report.
The containerized agent has already run its own compile → test → judge → refine loop, so the result it returns is final and every change it made is already applied.
