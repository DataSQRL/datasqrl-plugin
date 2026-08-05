---
name: implement
description: Use when the user has reviewed a DataSQRL plan and explicitly approved implementing it - for example by saying it looks good, to go ahead, or to implement it. Runs the DataSQRL Code Agent in implementation mode over that plan, the full autonomous implement, compile, test, verify and refine loop. Requires an existing adr/plan_*.md that was summarized to the user in this conversation; takes an optional path to a specific plan.
argument-hint: "[optional path to a plan_*.md]"
allowed-tools: Bash, Monitor, Read
---
Run the DataSQRL Code Agent in **implementation** mode (implement → compile → test → verify →
refine) on the current project.

**Working directory:** run everything below from the **project** directory. `codeagent.sh` derives
the project and its mounts from the current directory (`git rev-parse --show-prefix`), so launching
from the repository root instead treats the whole repo as one project, makes the entire repo
writable, and auto-discovers `adr/plan_*.md` at the repo root rather than in your project.

## Preconditions — check all three before running anything

1. An `adr/plan_*.md` exists.
2. Its summary was shown to the user **in this conversation**.
3. The user **explicitly approved implementing**, in their own words.

**"Build me a DataSQRL pipeline" is approval to start the workflow, not approval to implement.**

If any precondition is unmet, say which one, name the next command, and stop. This is a 30-60+
minute run that rewrites project files; starting it on a plan nobody read wastes real time and
money.

**The run and the command that starts it are two different things.** Keep them apart:

- **The run** is a 30-60+ minute container — far longer than any command you are allowed to hold
  open. It is therefore **detached**, owned by the Docker daemon rather than this session, and
  keeps going if this session is interrupted or closed.
- **The launch command** in step 1 is not the run. It only *starts* the container and exits, in
  about two seconds, printing the run name.

So the launch is an ordinary, fast, foreground command. There is nothing to wait on: do not wrap it
in a background shell, do not raise its timeout, and never launch it twice.

## Step 1 — start the run

```bash
CODEAGENT="${CLAUDE_PLUGIN_ROOT}/scripts/codeagent.sh"
[ -f "$CODEAGENT" ] || CODEAGENT=codeagent.sh   # fall back to PATH

bash "$CODEAGENT" "$ARGUMENTS" --mode implementation --detach
```

Run this normally, in the foreground, with the default timeout. It returns in about two seconds and
prints one line — the run name. Seeing that line means the container **started**, not that the
implementation has finished.

- With no argument it auto-discovers the latest `adr/plan_*.md`. Pass a path to target a specific
  plan.
- **Run the first two lines exactly as written.** They locate the launcher (codeagent.sh script).
- A **non-zero exit means the run never started** — failed preflight (Docker down, image missing,
  no credential) or a run already in progress for this project. Report that message verbatim and
  stop. Do not retry, do not work around it, do not go to step 2.

## Step 2 — watch it

If your agent can watch a background command (Claude Code: the `Monitor` tool, `persistent: true`),
watch:

```bash
bash "$CODEAGENT" --watch
```

It prints one short progress line per milestone and exits on its own at a terminal state, so the
watcher ends itself — do not set a timeout or stop it early.

If your agent has no such facility, say the run is underway and can be checked with the `status`
skill.

Either way: tell the user in one sentence that the run is underway and that they can close this
session without stopping it. **End your turn there.** Do not poll, sleep, or re-run anything while
it works.

## Step 3 — when the run finishes

The last event is terminal (`Finished · …` or `Error · …`). Only then:

1. Read `.code_agent_results.json` and summarize it: success, mode, scenario, refinements, issue
   score/count. If the file is missing, say so and quote the last event instead. **That summary is
   the entire deliverable — then stop.**
2. Do **not** ask a follow-up question. Not "should I fix this?", not "want me to look into the
   failure?", not "shall I re-run?".
3. Do **not** inspect the project: no `.sqrl`/`.json`/GraphQL/test files, no `git diff`/
   `git status`/`ls`/`grep`, no opening the plan or `build/`, no logs.
4. Do **not** review, critique, verify, or debug the implementation. The containerized agent
   already ran its own compile → test → judge → refine loop; **a failure it reports is a finished
   result, not a task handed to you.**
5. Do **not** propose follow-up work, fixes, or next steps, and do **not** edit any file.

These rules apply to every outcome: success, judge rejection, compile/test failure, or error.
There is no case in which you investigate.
