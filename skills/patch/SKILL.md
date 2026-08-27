---
name: patch
description: Use for a small, well-scoped change to an existing DataSQRL project. Runs the DataSQRL Code Agent in patch mode, which implements the requested changes, updates the tests and documentation they affect, runs the tests and refines if tests fail. Patch mode is not for anything complex or requiring large updates.
argument-hint: "<what to change>"
allowed-tools: Bash, Monitor, Read
---
Run the DataSQRL Code Agent in **patch** mode on the current project: the request goes straight to the implementing agent, which makes the change, updates and run the tests, updates what the change breaks, gets one round to fix what it catches, and updates the documentation.

No planning stage, no judge panel, one round to fix whatever the tests catch.

**Working directory:** run everything below from the **project** directory. `codeagent.sh` derives
the project and its mounts from the current directory (`git rev-parse --show-prefix`), so launching
from the repository root instead treats the whole repo as one project and makes all of it writable.

## When this is the right mode

Patch fits a change that satisfies all three:

- the project already exists
- the request determines the minor change
- it touches a handful of existing files at most

When any of the three fails, tell the user which condition the request misses and that the change needs designing, then ask whether to switch to the full workflow: `requirements` → `plan` → `implement`. When they choose the full workflow, hand off to the [`start` skill](../start/SKILL.md). When they choose to patch anyway, continue with Step 1 below.

For such a change `patch` is the whole workflow: one run, straight to implementation. The request string is the requirement, and the agent container writes it to `adr/requirements_<ts>.md` at runtime.

**Working directory**: run `codeagent.sh` in the project directory, the one containing the `adr` subfolder and the project implementation files. The command mounts the entire repository for the agent to read, and the invocation directory is the only one it writes to.

## Step 1 — start the run

The launch command starts a detached container and returns in about two seconds, printing the run name. Launch once, in the foreground, with the default timeout. The container is owned by the Docker daemon and keeps running after this session is interrupted or closed.

```bash
CODEAGENT="${CLAUDE_PLUGIN_ROOT}/scripts/codeagent.sh"
[ -f "$CODEAGENT" ] || CODEAGENT=codeagent.sh   # fall back to PATH

bash "$CODEAGENT" "$ARGUMENTS" --mode patch --detach
```

- **Run the first two lines exactly as written.** They locate the launcher (`codeagent.sh`).
- Pass the user's request as `$ARGUMENTS`, a single quoted string. Include the context user gave you, in particular anything they already changed by hand. The container sees only this string.
- The printed run name confirms the container **started**. Completion is signalled by the terminal event in step 2.
- A non-zero exit means the run never started — failed preflight (Docker down, image missing, no credential), or a run already in progress for this project. Report that message verbatim and end the turn.

## Step 2 — watch it

If your agent can watch a background command (Claude Code: the `Monitor` tool, `persistent: true`), watch:

```bash
bash "$CODEAGENT" --watch
```

It prints one short progress line per milestone and exits on its own at a terminal state, so the watcher ends itself — do not set a timeout or stop it early.

If your agent has no such facility, say the run is underway and can be checked with the [`status` skill](../status/SKILL.md).

Either way: tell the user in one sentence that the run is underway and that they can close this session without stopping it, then end your turn. The container keeps working while this session sits idle.

## Step 3 — when the run finishes

The last event is terminal (`Finished · …` or `Error · …`). Read `.code_agent_results.json` and report success, mode, and refinements. If the file is absent, quote the last event instead.
That report is the complete deliverable, for every outcome. Stop after the report.
The containerized agent has already run its own implement → test → fix loop, so the result it returns is final and every change it made is already applied.
