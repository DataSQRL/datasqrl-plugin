---
name: plan
description: Use when DataSQRL requirements exist and the next step is a plan, or when the user asks to plan a DataSQRL pipeline or data catalog. Runs the DataSQRL Code Agent in planning mode over a requirements document or a requirements string, producing a reviewable, checkbox-tracked adr/plan_<ts>.md. Takes an optional path to a requirements .md, or inline requirements text.
argument-hint: <requirements text | path to a requirements .md>
allowed-tools: Bash, Read, Skill
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
- The printed run name confirms the container **started**.
- A non-zero exit means the run never started — failed preflight (Docker down, image missing, no credential), or a run already in progress for this project. Report that message verbatim and end the turn.

## Step 2 — start the background wait

Start this command **in the background**, with the longest timeout you can set:

```bash
bash "$CODEAGENT" --wait
```

It waits until the run ends and then prints one line with the result. Because it runs in the background, you get a notice when it ends, and the user does not have to ask you. If you cannot run a command in the background, skip this step; the user will ask you how the run went.

## Step 3 — inform the user, then end your turn

Write this message after the background command has started, as the last message of the turn, so the user sees it in full (text written before a command call can be hidden by the user's interface). The message contains, in full:

- the run name the launch printed;
- the block of commands the launch printed under the run name, copied word for word — each line is an action the user can take from a terminal;
- that the user can ask you at any time how the run is going or what a progress line means (the [`progress` skill](../progress/SKILL.md) answers that), and can ask you to stop the run;
- that the container keeps working while this session sits idle;
- that you will report when the run ends (only when the background wait is running).

Then end your turn.

## Step 4 — when the background `--wait` stops because of the timeout

The run is still going. Start the same `--wait` command again in the background and end your turn.

## Step 5 — when the run finishes

Do this when the background `--wait` ends with the line `No run in progress. Last result: …`, or when the user asks you how the run went (the [`progress` skill](../progress/SKILL.md) tells you whether it has finished) and it shows that the run finished.

1. Read the newly created `adr/plan_*.md` and summarize its scenario, high-impact assumptions, and implementation checklist. That plan file is the sole source for the summary. If no new plan file exists, say so.
2. End with exactly one question:

   > The plan is at `adr/plan_<ts>.md`. Please review it — especially the assumptions. Refactor the plan if something is off. Once it looks right, tell me and I'll run the implementation.

The summary plus that question is the complete deliverable. Reviewing the plan belongs to the user; implementation starts when they come back and approve.

For a failed run, report the failure and end the turn.
