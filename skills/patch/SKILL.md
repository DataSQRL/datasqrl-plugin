---
name: patch
description: Use for a small, well-scoped change to an existing DataSQRL project. Runs the DataSQRL Code Agent in patch mode, which implements the requested changes, updates the tests and documentation they affect, runs the tests and refines if tests fail. Patch mode is not for anything complex or requiring large updates.
argument-hint: "<what to change>"
allowed-tools: Bash, Monitor, Read
---
Run the DataSQRL Code Agent in **patch** mode on the current project: the request goes straight to the implementing agent, which makes the change, updates and run the tests, updates what the change breaks and updates the documentation.

No planning stage, no judge panel, one round to fix whatever the tests catch.

**Working directory:** run everything below from the **project** directory. `codeagent.sh` derives
the project and its mounts from the current directory (`git rev-parse --show-prefix`), so launching
from the repository root instead treats the whole repo as one project and makes all of it writable.

## When this is the right mode

The overall requested edit is small and doesn't require complex planning stage and the implementation can be direclty started.

- You do **not** need a plan, a requirements document, or a review stage — that is the point of the
mode. When you launch the agent, it writes the request to `adr/requirements_<ts>.md` itself, so there is nothing for you
to author. 
- **Do not invoke the `requirements` skill**: producing a requirements document.

**The run and the command that starts it are two different things.** Keep them apart:

- **The run** is a container that takes several minutes — longer than any command you are allowed to
  hold open. It is therefore **detached**, owned by the Docker daemon, and keeps going if this
  session is interrupted or closed.
- **The launch command** It only *starts* the container and exits, in
  about two seconds, printing the run name.

So the launch is an ordinary, fast, foreground command. There is nothing to wait on: do not wrap it
in a background shell, do not raise its timeout, and never launch it twice.

## Step 1 — start the run

```bash
CODEAGENT="${CLAUDE_PLUGIN_ROOT}/scripts/codeagent.sh"
[ -f "$CODEAGENT" ] || CODEAGENT=codeagent.sh   # fall back to PATH

bash "$CODEAGENT" "$ARGUMENTS" --mode patch --detach
```

Run this normally, in the foreground, with the default timeout. It returns in about two seconds and
prints one line — the run name. Seeing that line means the container **started**, not that the patch
is finished.

- **Run the first two lines exactly as written.** They locate the launcher (codeagent.sh script).
- Pass the user's request as `$ARGUMENTS`, as a single quoted string. Include the context they gave
  you — in particular anything they already changed by hand, since the agent cannot see this
  conversation and will otherwise re-derive or undo it.
- A **non-zero exit means the run never started** — failed preflight (Docker down, image missing, no
  credential) or a run already in progress for this project. Report that message verbatim and stop.
  Do not retry, do not work around it, do not go to step 2.

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

1. Read `.code_agent_results.json` and summarize it: success, mode, refinements. If the file is
   missing, say so and quote the last event instead. **That summary is the entire deliverable —
   then stop.**
2. Do **not** ask a follow-up question. Not "should I fix this?", not "want me to look into the
   failure?", not "shall I re-run?".
3. Do **not** inspect the project: no `.sqrl`/`.json`/GraphQL/test files, no `git diff`/
   `git status`/`ls`/`grep`, no opening `build/`, no logs.
4. Do **not** review, critique, verify, or debug the change. The containerized agent already ran its
   own implement → test → fix loop; **a failure it reports is a finished result, not a task handed
   to you.**
5. Do **not** propose follow-up work, fixes, or next steps, and do **not** edit any file.

These rules apply to every outcome: success, test failure, or error. There is no case in which you
investigate.