---
name: plan
description: Use when DataSQRL requirements exist and the next step is a plan, or when the user asks to plan a DataSQRL pipeline or data catalog. Runs the DataSQRL Code Agent in planning mode over a requirements document or a requirements string, producing a reviewable, checkbox-tracked adr/plan_<ts>.md. Takes an optional path to a requirements .md, or inline requirements text.
argument-hint: <requirements text | path to a requirements .md>
allowed-tools: Bash, Monitor, Read, Skill
---
Run the DataSQRL Code Agent in **planning** mode on the current project.

**Working directory**: run `codeagent.sh` in the project directory — the one containing the `adr` subfolder and the project implementation files. The command mounts the entire repository for the agent to read, and the invocation directory is the only one it writes to. `adr/` is resolved relative to that directory.

**Precondition:** the requirements come from the user — a file they wrote or approved, or text they gave you. When no requirements document exists yet, use the [`requirements` skill](../requirements/SKILL.md) first.

## Step 1 — start the run

The launch command starts a detached container and returns in about two seconds, printing the run name. Launch once, in the foreground, with the default timeout. The container is owned by the Docker daemon and keeps running after this session is interrupted or closed.

```bash
CODEAGENT="${CLAUDE_PLUGIN_ROOT}/scripts/codeagent.sh"
[ -f "$CODEAGENT" ] || CODEAGENT=codeagent.sh   # fall back to PATH

bash "$CODEAGENT" "$ARGUMENTS" --mode planning --detach
```

- **Run the first two lines exactly as written.** They locate the launcher (`codeagent.sh`).
- `$ARGUMENTS` is inline requirements text, or a path to a requirements file inside the project (adr/requirements_<>.md). When it is a path, confirm the file exists before launching.
- Pass `$ARGUMENTS` verbatim and launch immediately. The planning agent records its own assumptions for anything the requirements leave unspecified.
- The printed run name confirms the container **started**. Completion is signalled by the terminal event in step 2.
- A non-zero exit means the run never started — failed preflight (Docker down, image missing, no credential), or a run already in progress for this project. Report that message verbatim and end the turn.

## Step 2 — watch it

If your agent can watch a background command (Claude Code: the `Monitor` tool, `persistent: true`), watch:

```bash
bash "$CODEAGENT" --watch
```

It prints one short progress line per milestone and exits on its own at a terminal state, so the watcher ends itself — do not set a timeout or stop it early.

If your agent has no such facility, say the run is underway and can be checked with the [`status` skill](../status/SKILL.md).

Either way: say in one sentence that planning is underway, then end your turn. The container keeps working while this session sits idle.

## Step 3 — when the run finishes

The last event is terminal (`Finished · …` or `Error · …`).

1. Read the newly created `adr/plan_*.md` and summarize its scenario, high-impact assumptions, and implementation checklist. That plan file is the sole source for the summary. If no new plan file exists, say so and quote the last event instead.
2. End with exactly one question:

   > The plan is at `adr/plan_<ts>.md`. Please review it — especially the assumptions. Refactor the plan if something is off. Once it looks right, tell me and I'll run the implementation.

The summary plus that question is the complete deliverable. Reviewing the plan belongs to the user; implementation starts when they come back and approve.

For a failed run, report the failure and end the turn.
