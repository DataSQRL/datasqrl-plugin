---
name: plan
description: Use when DataSQRL requirements exist and the next step is a plan, or when the user asks to plan a DataSQRL pipeline or data catalog. Reviews the requirements for missing architecture drivers, then runs the DataSQRL Code Agent in planning mode over a requirements document or a requirements string, producing a reviewable, checkbox-tracked adr/plan_<ts>.md. Takes an optional path to a requirements .md, or inline requirements text.
argument-hint: <requirements text | path to a requirements .md>
allowed-tools: Bash, Read, Edit, Skill
---
Run the DataSQRL Code Agent in **planning** mode on the current project.

**Working directory**: run `datasqrl-agent.sh` in the project directory — the one containing the `adr` subfolder and the project implementation files. The command mounts the entire repository for the agent to read, and the invocation directory is the only one it writes to. `adr/` is resolved relative to that directory.

**Precondition:** the requirements come from the user — a file they wrote or approved, or text they gave you. When no requirements document exists yet, use the [`requirements` skill](../requirements/SKILL.md) first.

## Step 0 — review the requirements

Read the requirements (the file at `$ARGUMENTS`, or the inline text) and check each [architecture driver](../requirements/SKILL.md#architecture-drivers):

1. Sources, and which data the project captures and manages itself (API, Kafka topic, Iceberg table)
2. Results (data lake / data product, API, stream) and whether they need authorization
3. Freshness as an acceptable staleness; a "realtime" requirement says why minutes would not do
4. Workload, budget and reliability
5. API latency SLA, when results are served through an API
6. Authorization claims (API) or tags (data lake / data product), when access is authorized
7. What, not how: any how is a marked hard constraint

A driver is covered when it has a stated value, an open question with a recommended default, or an explicit note that it does not apply.

- **All covered**: go to Step 1 without asking.
- **Gaps found**: list each gap in one line (what is missing, and what the planner will assume in its place), then ask the user whether to clarify or to plan as is, and **wait for their answer**.
  - **They clarify**: write their answers into the requirements file (for inline text, fold them into the text you pass), then go to Step 1.
  - **They proceed**: go to Step 1 with the requirements unchanged. The planner records its own assumptions for the gaps.

## Step 1 — start the run

The launch command starts a detached container and returns in about two seconds, printing the run name. Launch once, in the foreground, with the default timeout. The container is owned by the Docker daemon and keeps running after this session is interrupted or closed.

```bash
CODEAGENT="${CLAUDE_PLUGIN_ROOT}/scripts/datasqrl-agent.sh"
[ -f "$CODEAGENT" ] || CODEAGENT=datasqrl-agent.sh   # fall back to PATH

bash "$CODEAGENT" "$ARGUMENTS" --mode planning --detach [run choices]
```

- **Run the first two lines exactly as written.** They locate the launcher (`datasqrl-agent.sh`).
- **Run choices:** run with the choices settled during setup, as [`agent-setup.md`](../start/reference/agent-setup.md#passing-the-run-choices) describes. With none settled, add nothing: the run uses the defaults.
- `$ARGUMENTS` is inline requirements text, or a path to a requirements file inside the project (adr/requirements_<>.md). When it is a path, confirm the file exists before launching.
- Pass `$ARGUMENTS` verbatim (with any clarifications from Step 0 folded in) and launch without further review. The planning agent records its own assumptions for anything the requirements leave unspecified.
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
