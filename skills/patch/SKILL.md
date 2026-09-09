---
name: patch
description: Use for a small, well-scoped change to an existing DataSQRL project. Runs the DataSQRL Code Agent in patch mode, which implements the requested changes, updates the tests and documentation they affect, runs the tests and refines if tests fail. Patch mode is not for anything complex or requiring large updates.
argument-hint: "<what to change>"
allowed-tools: Bash, Read
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

Read `.code_agent_results.json` and report success, mode, refinements, and issue score/count. If the file is absent, say so.
That report is the complete deliverable, for every outcome. Stop after the report.
The containerized agent has already run its own implement → test → fix loop, so the result it returns is final and every change it made is already applied.
