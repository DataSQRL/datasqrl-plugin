---
name: plan
description: Use when DataSQRL requirements exist and the next step is a plan, or when the user asks to plan a DataSQRL pipeline or data catalog. Runs the DataSQRL Code Agent in planning mode over a requirements document or a requirements string, producing a reviewable, checkbox-tracked adr/plan_<ts>.md. Takes an optional path to a requirements .md, or inline requirements text.
argument-hint: <requirements text | path to a requirements .md>
allowed-tools: Bash, Monitor, Read, Skill
---
Run the DataSQRL Code Agent in **planning** mode on the current project.

**Working directory:** run everything below from the **project** directory. `codeagent.sh` derives
the project and its mounts from the current directory (`git rev-parse --show-prefix`), so launching
from the repository root instead treats the whole repo as one project and resolves `adr/` at the
repo root. A requirements path that does not resolve is not an error — it is taken as literal
requirements text, and the planner plans for the filename.

**Precondition:** the requirements must come from the user — a file they wrote or approved, or text
they gave you. Never invent requirements and immediately plan on them. If there is no requirements
document yet, use the `requirements` skill first.

**The run and the command that starts it are two different things.** Keep them apart:

- **The run** is a container that can take longer than any command you are allowed to hold open. It
  is therefore **detached** — owned by the Docker daemon, not by this session. It keeps going if
  this session is interrupted or closed.
- **The launch command** in step 1 is not the run. It only *starts* the container and exits, in
  about two seconds, printing the run name.

So the launch is an ordinary, fast, foreground command. There is nothing to wait on: do not wrap it
in a background shell, do not raise its timeout, and never launch it twice.

## Step 1 — start the run

```bash
CODEAGENT="${CLAUDE_PLUGIN_ROOT}/scripts/codeagent.sh"
[ -f "$CODEAGENT" ] || CODEAGENT=codeagent.sh   # fall back to PATH

bash "$CODEAGENT" "$ARGUMENTS" --mode planning --detach
```

Run this normally, in the foreground, with the default timeout. It returns in about two seconds and
prints one line — the run name. Seeing that line means the container **started**, not that planning
has finished.

- `$ARGUMENTS` is inline requirements text *or* a path to a requirements file inside the project.
- **Run the first two lines exactly as written.** They locate the launcher (codeagent.sh script).
- A **non-zero exit means the run never started** — failed preflight (Docker down, image missing,
  no credential) or a run already in progress for this project. Report that message verbatim and
  stop. Do not retry, do not work around it, do not go to step 2.

Start the run immediately. Do not ask questions or survey the project first. Pass `$ARGUMENTS`
through verbatim even if it looks incomplete — the planning agent records its own assumptions.

## Step 2 — watch it

If your agent can watch a background command (Claude Code: the `Monitor` tool, `persistent: true`),
watch:

```bash
bash "$CODEAGENT" --watch
```

It prints one short progress line per milestone and exits on its own at a terminal state, so the
watcher ends itself — do not set a timeout or stop it early.

If your agent has no such facility, say the run is underway and can be checked with the `status`
skill, and end your turn.

Either way: say in one sentence that planning is underway, then **end your turn**. Do not poll or
sleep.

## Step 3 — when the run finishes

The last event is terminal (`Finished · …` or `Error · …`). Only then:

1. Read the newly created `adr/plan_*.md` and summarize its scenario, high-impact assumptions, and
   implementation checklist, so the user can review before implementing. If no new plan file
   exists, say so and quote the last event instead.
2. **Then offer the next step, and stop.** Exactly one question is allowed, and this is it:

   > The plan is at `adr/plan_<ts>.md`. Please review it — especially the assumptions above. Once
   > it looks right, tell me and I'll run the implementation.

   Ask nothing else. Not "should I adjust the plan?", not "shall I re-run?", not "want me to look
   into that?". Then end your turn and wait.
3. Do **not** inspect the project beyond that one plan file: no `.sqrl`/`.json`/GraphQL/test files,
   no `git diff`/`git status`/`grep`, no logs.
4. Do **not** critique the plan, revise it, edit any file, or start implementing. **Reviewing the
   plan is the user's job.** The offer above is an invitation to review, not permission to skip it —
   implementation starts only after they come back and approve.

If the run **failed**, the offer does not apply: report the failure and stop. Do not offer to
re-run, diagnose, or work around it.

These rules apply to every outcome. There is no case in which you investigate.
