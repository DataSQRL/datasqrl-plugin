---
name: start
description: Use whenever the user wants to build, extend, change, or plan a DataSQRL data pipeline or data catalog - including ingesting a source (Kafka topic, webhook, REST endpoint, database, file) into DataSQRL, exposing a GraphQL or REST API over streaming data, or writing a requirements document for such work, or resolving a GitHub issue filed on a DataSQRL project. Also use when they mention DataSQRL, SQRL, .sqrl files, or ask how to get started with one, and when they want to deploy, ship or release a DataSQRL project to DataSQRL Cloud, check on a deployment, or promote one to main. This skill owns the whole workflow; it decides what happens next and delegates each step.
---
# Build or deploy

This skill answers two kinds of request Decide which kind the request is, read that section only, and stop where it stops.

| The request | Read |
|---|---|
| changes files in the project: a new pipeline or catalog, a feature, a fix, a requirements document, a plan | [Building with DataSQRL](#building-with-datasqrl), next |
| moves the project to DataSQRL Cloud: deploy, ship or release it, check a deployment's status or logs, sign in, promote a deployment to main | [Deploying to DataSQRL Cloud](#deploying-to-datasqrl-cloud), at the end |

Building DataSQRL runs a containerized agent that writes into the
working tree and leaves its work uncommitted, for the user to commit. 
Deploying writes nothing locally: the DataSQRL Cloud API deploys a commit that GitHub already has. The user's own commit and push sits between the two, so no request is both, and neither section continues into the other on its own.

A request that adds or edits a project file is a building event even when it says "deployment", such as a production environment config or a new deploy target (see [Building with DataSQRL](#building-with-datasqrl)). A request that tells to deploy a project in DataSQRL Cloud, or a commit to ship, i.e. asks for nothing to be written in the project, can be considered deploying (see Deploying to DataSQRL Cloud](#deploying-to-datasqrl-cloud)).

---

# Building with DataSQRL

A containerized code agent builds DataSQRL projects. It holds the SQRL compiler, the DataSQRL
skill library, a test runner and reviewing judges. This section sets up the environment, routes to
a lane, invokes the agent, and reports what the agent returns.

A request to resolve a GitHub issue — the user gives its URL or number, or points at an issue the DataSQRL Cloud assistant filed — goes to the [`resolve-issue` skill](../resolve-issue/SKILL.md) instead of the steps below. It locates the project from the issue, writes the issue as requirements, and picks the lane the fix needs.

There are two lanes, and this section takes them in order:

| | Step 1 · Setup | Step 2 · Route | Step 3 · Run |
|---|---|---|---|
| **Lane A — Patch** | image + git location | small, fully-determined change | one `patch` run |
| **Lane B — Full workflow** | image + git location | anything that needs designing | `requirements` (optional-depending on the user request) → `plan` → `implement` |

## File ownership

The containerized agent writes every file of the DataSQRL project: `.sqrl` scripts,
`*-package.json` configs, GraphQL schemas and operations, connector configs, test files and
snapshots. This holds for a new project in an empty directory — the agent creates the directory
layout itself.

In Lane B only: `adr/requirements_<ts>.md` file is created via the `requirements` skill. In Lane A the container persists the request string itself. The `resolve-issue` skill writes that file from the issue in either lane.

---

## Step 1 — Setup (both lanes A&B, before routing)

### 1a. Make sure the agent image is here

Run this once, at the start. It is a no-op when the image is already present:

```bash
if ! docker image inspect datasqrl-code-agent:latest >/dev/null 2>&1; then
  echo "Fetching the DataSQRL agent image..."
  docker pull ghcr.io/datasqrl/code-agent:latest &&
    docker tag ghcr.io/datasqrl/code-agent:latest datasqrl-code-agent:latest
fi
```

Run it without prompting. On success, continue to 1b silently.

#### If it fails

Relay Docker's own message, then apply the matching fix.

| Docker's error says | Meaning | What to do |
|---|---|---|
| `denied`, `unauthorized` | the package is private | give the user the GHCR login below |
| `Cannot connect to the Docker daemon` | Docker is not running | ask them to start Docker, then retry once |
| anything else | unknown | relay it verbatim and stop |

For a denied pull:

> Create a GitHub personal access token (classic) with the `read:packages` scope at
> <https://github.com/settings/tokens>, then run:
> ```
> echo "$GITHUB_PAT" | docker login ghcr.io -u <your-github-username> --password-stdin
> ```

### 1b. Locate the project

Run these two commands in the directory the user wants to build in:

```bash
git rev-parse --show-toplevel   # the repository root
git rev-parse --show-prefix     # this project's path inside the repo (empty at the root)
```

Their output determines the layout completely. An empty `--show-prefix` means the project *is* the repository. A non-empty one means the project is a subdirectory, and sibling projects may exist alongside it. Route from that output.

#### If a repository is found

Report it in one line:

> Building `<prefix>` in the git repository `<toplevel>`. Ask user if that is not the repo he/she meant.

#### If no repository is found

A run requires a git repository. Creating one changes the user's filesystem, so ask:

> There is no git repository here. Shall I run `git init` in `<absolute path of cwd>`?

The current directory is the default. Offer the parent instead when the user names a sibling project or shared data catalog this project must read (live in the same repository) and gives no path.

#### Mounts

The repository is bind-mounted, so the agent's writes land in the user's real files. The invocation directory is the only writable mount; the rest of the repository (sibling projects or shared data catalog) is mounted read-only for reference. Invoke from the project directory.

---

## Step 2 — Route

### Lane A — patch

Lane A applies a change the request already determines: the agent applies it, updates the tests and documentation it affects, runs the tests and repairs what it breaks. A change that needs designing, refactoring or a major update belongs in Lane B.

Choose Lane A when all three hold:

- the project already exists
- the request fully determines the minor change
- it touches a handful of existing files at most

Typical examples for Lane A (patch work): 
- adjusting a time window or watermark, 
- renaming a field, 
- changing a setting on an existing connector, 
- adding a test case, or reconciling tests and docs after the user hand-edited a `.sqrl` file.

### Lane B — full workflow

Any one of these selects Lane B:

- there are no `.sqrl` files yet
- a new sub-project or environment configuration
- substantial new logic
- the user supplied payloads, a spec, a ticket, or acceptance criteria — that material has to be carried into a plan verbatim
- the request leaves anything open that you would otherwise decide on the user's behalf
- user asked for a plan
- user requested to write a requirement file

A single Lane B signal, then select Lane B. Route without asking when the signals are clear; when the decision needs the user, ask in one line and state your default.

---

## Step 3, Lane A — Patch

Use the `patch` skill. That is the entire lane.

Pass the user's request as a single quoted string, including any context they gave. The agent implements, compiles and tests directly, and iterates one time if necessary.

When the run finishes, report the result and stop — see **After any agent run**.

---

## Step 3, Lane B — Full workflow

| Stage | Who does it | Skill |
|-------|-------------|-------|
| 1. Requirements | you, with the user | `requirements` |
| 2. **Requirements review** | **the user** | — |
| 3. Plan | containerized agent | `plan` |
| 4. **Plan review** | **the user** | — |
| 5. Implement | containerized agent | `implement` |

Stages 2 and 4 belong to the user. Each is a stop: wait for their reply before continuing.
Stages 3 and 5 each start a detached run, hand the user the commands to follow it, and start a background `--wait` that tells you when the run ends

### How each stage ends

Every stage ends with a question you need answered, or an offer to run the next stage.

| After | End with |
|---|---|
| the requirements are written | *"review them — once they look right, tell me and I'll run planning"* |
| the plan is written | *"review it — once it looks right, tell me and I'll run the implementation"* |
| the implementation finishes | the result summary. The run is the end of the workflow. |

The offer invites the user to read the file; advance to the next stage on their reply. Report a failed run and end the turn.

### 1. Requirements, and 2. their review

Use the [`requirements` skill](../requirements/SKILL.md), unless the user already has a requirements document. Planning converts every gap in the requirements into a recorded assumption, so run this stage for a simple-sounding request too.

That skill ends by listing the open questions and asking the user to review the document. Wait for their answer. When they answer open questions in the chat, write the answers into the requirements file first; the planner reads the requirements file only. With the user confirmation, continue with the planning stage by invoking [`plan` skill](../plan/SKILL.md)

### 3. Plan

Use the [`plan` skill](../plan/SKILL.md). It writes `adr/plan_<ts>.md`, persistent checkbox-tracked plan.

### 4. Ask User to review the plan 

Stop and let them read the plan, especially its `## Assumptions` (high-impact ones are tagged) and its `## Implementation Checklist`. They may edit the file directly before implementing.

### 5. Implement

Use the [`implement` skill](../implement/SKILL.md) once all all following item hold:

1. An `adr/plan_*.md` exists.
2. Its summary was shown to the user in this conversation.
3. The user explicitly approved implementing, in their own words.

Condition 3 is satisfied by a statement referring to the plan just summarized — for example "looks good, implement it". When a condition is unmet, name it, name the command that satisfies it, and stop. Implementation is a 30-60+ minute containerized run that writes project files, runs tests, and verifies the generated code iteratively.

---

## Both lanes

### After any agent run

The containerized agent runs its own compile → test → refine loop, plus judges in Lane B. Report the outcome it returns and end the turn. Every outcome (success, judge rejection, compile failure, test failure, error) is a finished result.

The result is the end of the build. The agent does not commit the changes automatically, so the agent's work might be uncommitted in the working tree. After the agent run, express user to observe and review the changes done by agent, and then if the latest changes meet their requirements, tell them that they may commit and push the latest changes to remote remo.
Deploying begins when the user asks for it, as a request of its own.

### Checking on a run

The [`plan`](../plan/SKILL.md), [`implement`](../implement/SKILL.md) and [`patch`](../patch/SKILL.md) skills hand the user the commands to follow the run and start a background `--wait` that tells you when the run ends; the [`progress`](../progress/SKILL.md) skill answers how it is going, explains the progress output, and stops the run when asked.

---

# Deploying to DataSQRL Cloud

Shipping to DataSQRL Cloud is two skills, and each is a **separate request the user makes**. Both
reach the Cloud API through `scripts/datasqrl-cloud.sh` and need neither Docker nor the agent image. So, invoke the skill directly.

| When the user asks to… | Invoke |
|---|---|
| deploy, ship or release the project; create a deployment | the `deploy` skill |
| check how a deployment is going, read its status or logs | the `deploy` skill |
| sign in to DataSQRL Cloud, or list their organizations or projects | the `deploy` skill |
| make a deployment the project's **main** one — promote it, point production at it | the `promote` skill |

Invoke the skill and let it run its own steps; it handles the git checks, the sign-in, the choice of commit and the project lookup itself.

Two conditions keep this section honest:

- **Wait to be asked.** This section opens on the user's own request. After a build run, report the result, ask the user to review the changes and tell them they may commit and push, as [After any agent run](#after-any-agent-run) says. The user decides when that code ships, in a request of their own.
- **A deploy never promotes.** Adding a deployment changes nothing about which one is main, so "deploy and ship it" is a deploy, and promoting stays a fresh request. Invoke `promote` only when the user asks for it in its own right, after seeing a deploy result.
