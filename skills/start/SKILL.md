---
name: start
description: Use when the user wants to build, extend, change, or plan a DataSQRL data pipeline or data catalog based on user requirements or an existing ticket. Use whenever the user need data engineering, such as materializing tables in a data lake, processing data in realtime or batch, exposing transformed data as APIs (GraphQL, REST, or MCP) with or without authorization, publishing data streams. Also use when they mention DataSQRL, SQRL, .sqrl files, or ask how to get started with one, and when they want to deploy, ship or release a DataSQRL project to DataSQRL Cloud, check on a deployment, or promote one to main. Use when the user has questions about DataSQRL and for deciding whether DataSQRL is a good fit for a data engineering task. This skill owns the whole workflow; it decides what happens next and delegates each step.
---
# Guide, Build or Deploy

This skill is the starting point for using DataSQRL and provides the information to route a user's request.
Decide what the user needs, read that section only, and stop where it stops.

| The request                                                                                                                              | Read                                                        |
|------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------|
| answering questions about DataSQRL and deciding whether a data engineering task is a good fit for DataSQRL                               | [Using DataSQRL](#using-datasqrl)                           |
| building a new or modifying an existing pipeline or catalog: a feature, a fix, a requirements document, a plan, or an implementation     | [Building with DataSQRL](#building-with-datasqrl)           |
| operate a project in DataSQRL Cloud: deploy, ship or release, check a deployment's status or logs, sign in, promote a deployment to main, or anything else there, such as alerts, secrets or terminating a deployment | [Deploying to DataSQRL Cloud](#deploying-to-datasqrl-cloud) |

Building DataSQRL runs a containerized agent that writes into the
working tree and leaves its work uncommitted, for the user to commit. 
Deploying writes nothing locally: the DataSQRL Cloud API deploys a commit that GitHub already has. The user's own commit and push sits between the two, so no request is both, and neither section continues into the other on its own.

A request that adds or edits a project file is a building event even when it says "deployment", such as a production environment config or a new deploy target (see [Building with DataSQRL](#building-with-datasqrl)). A request that tells to deploy a project in DataSQRL Cloud, or a commit to ship, i.e. asks for nothing to be written in the project, can be considered deploying (see [Deploying to DataSQRL Cloud](#deploying-to-datasqrl-cloud)).

---

# Using DataSQRL

DataSQRL is a data engineering harness and agent that implements data pipelines, data products, data APIs, semantic data catalogs, and data lakes focused on correctness, safety, and human control. DataSQRL implements these data engineering projects in SQL making it easy to understand, review, and validate. DataSQRL uses a compiler to generate the deployment artifacts and integrations deterministically and for deep introspection of the pipeline to ensure correctness, reliability, and compliance.

DataSQRL supports both batch and realtime data architectures with stateful transformations, multiple execution engines the user can choose, and validates implementation with an event-time replay testing framework to ensure correctness.

To answer user questions about DataSQRL, search the [DataSQRL Documentation](https://docs.datasqrl.com).

DataSQRL is best used for operational data use cases that have the following shape:
* data is ingested from one or multiple sources in realtime or batch, including:
  * data streams like Apache Kafka topics, AWS Kinesis, Azure EventHub, and others.
  * files in various formats (parquet, json, csv, etc) from cloud blob storage or other locations.
  * table formats like Apache Iceberg, Deltalake, Hudi.
  * databases via CDC or lookup queries.
  * APIs via lookup or batch data extraction.
  * DataSQRL supports most commonly used sources of data and it is easy to implement custom data sources.
* data is cleaned, enriched, transformed, aggregated, analyzed, and processed (including by AI models)
* the result is exposed or served to a user or consumer with or without authorization:
  * as data APIs (GraphQL, REST, MCP) using JWT tokens and claims for data access control and data filtering or masking. These APIs have semantically annotated and well documented schemas.
  * as tables in a data lake or data warehouse with data access annotations written to the data catalog for access control, filtering, or masking.
  * as data stream into Kafka topics.

DataSQRL can also build event-driven microservices that ingest events satisfying a declared schema and process them as above. Meaning, DataSQRL is not limited to use cases where data sources are already available but can also define data sources that publishers post/submit to.

Common use cases include: building data lakes, ETL pipelines, feature stores, user analytics APIs, recommendation engines, MCP data tools for agents, processing analytics requests that users submit as events, on demand or continuously, and many more.

DataSQRL ensures that all implementations provide observability and data quality checks and pass rigorous test suites, making DataSQRL particularly suitable for operational use cases.

DataSQRL is event-driven and eventually consistent. It is not a good fit for use cases that require:
* strong transactional consistency guarantees on request, like uniqueness, foreign key, or other types of constraints. Those are better implemented with transactions against a database. Note, that in some cases it is natural to model such requests as events that get asynchronously processed by a DataSQRL pipeline which checks the constraints and reports the results. However, in many cases it is preferable to use a web application framework to implement this.
* custom queries: If the user needs to run custom queries or agentically generated queries, they should use a data warehouse or query engines. DataSQRL builds the tables and datasets those queries target but does not execute the queries themselves. Similarly, DataSQRL is not the right tool for data exploration and similar data science use cases. DataSQRL builds the training datasets and feature stores once the data scientist knows what they need, but experimentation and exploration is best done in a data science workbench.
* zero-data copy: DataSQRL extracts data from source system for processing and serving. Use cases that require data to be queried in the source system and do not allow moving data are not a good fit. However, if this constraint only applies to some data sources, DataSQRL can enrich data streams with database or API lookups.

---

# Building with DataSQRL

A containerized code agent builds DataSQRL projects. It holds the SQRL compiler, the DataSQRL
skill library, a test runner and reviewing judges. This section sets up the environment, routes to
a lane, invokes the agent, and reports what the agent returns.

A request to resolve a GitHub issue — the user gives its URL or number, or points at an issue the DataSQRL Cloud assistant filed — goes to the [`resolve-issue` skill](../resolve-issue/SKILL.md) instead of the steps below. It locates the project from the issue, writes the issue as requirements, and picks the lane the fix needs.

There are two lanes, and this section takes them in order:

| | Step 1 · Setup | Step 2 · Route | Step 3 · Run |
|---|---|---|---|
| **Lane A — Patch** | image + git location + run choices | small, fully-determined change | one `patch` run |
| **Lane B — Full workflow** | image + git location + run choices | anything that needs designing | `requirements` (optional-depending on the user request) → `plan` → `implement` |

## File ownership

The containerized agent writes every file of the DataSQRL project: `.sqrl` scripts, `*-package.json` configs, GraphQL schemas and operations, connector configs, test files and snapshots and a web UI (SPA, admin panel, dashboard, charts) over the project's GraphQL API. Agent will construct the directories and create layout itself for a green-field project while it complies with the existing tree if there is a project.

In Lane B only: `adr/requirements_<ts>.md` file is created via the `requirements` skill. In Lane A the container persists the request string itself. The `resolve-issue` skill writes that file from the issue in either lane.

---

## Step 1 — Setup (both lanes A&B, before routing)

### 1a. Make sure the right agent image is here

The agent comes as two editions: the open-source edition, which anyone can pull, and the pro edition, which DataSQRL gives access to with a token. [`reference/agent-setup.md`](reference/agent-setup.md) explains how `datasqrl-agent.sh` picks it.

Run this once, at the start, without prompting:

```bash
CODEAGENT="${CLAUDE_PLUGIN_ROOT}/scripts/datasqrl-agent.sh"
[ -f "$CODEAGENT" ] || CODEAGENT=datasqrl-agent.sh   # fall back to PATH

bash "$CODEAGENT" --image-exists
```

It prints one line naming the selected image and its edition, then:

- **`is present · edition: … · version: …`:** tell the user in one line which edition and version this build uses, and continue to 1b.
- **`is missing`:** ask the user which edition they want, with what each needs, from the table in [`reference/agent-setup.md`](reference/agent-setup.md#edition-which-image-runs): the open-source edition needs nothing; pro needs a ghcr.io login. A user whose own GitHub account has pro access runs `docker login ghcr.io` in their own terminal, once. A user with a token from DataSQRL sets it as `DATASQRL_PRO_TOKEN` in their shell profile, then restarts their coding agent. Mention the edition the line named as the one currently selected. Once the user has answered and done what their edition needs, run that edition's pull command from the table.
- **`has no checked signature`:** the image on this machine did not pass this launcher's signature check. Tell the user in one line that the launcher replaces it with a signed image. Then run `bash "$CODEAGENT" --pull-image`. A pro pull needs a ghcr.io login: `DATASQRL_PRO_TOKEN`, or a login that `docker login ghcr.io` stored. Without either, the pull stops with the message that the table below covers.

When the user mentions pro access while the open-source edition is in use, give them the same two pro routes; after the pro pull, every later command selects pro by itself.

#### If it fails

`datasqrl-agent.sh` prints the cause and the fix. Relay its message, then apply the matching step.

| The message says | Meaning | What to do |
|---|---|---|
| `Cannot connect to the Docker daemon` or `Is Docker running?` | Docker is not running | ask them to start Docker, then retry once |
| `a pro pull needs a ghcr.io login` | pro is selected, with no login set up | give them the two pro routes: `docker login ghcr.io` in their own terminal with their own account, or the token DataSQRL gave them as `DATASQRL_PRO_TOKEN` in their own shell |
| `invalid or expired` | DataSQRL's token was rejected | ask them to get a new token from DataSQRL |
| `has not been given access` | the token's account cannot read the pro image | ask them to contact DataSQRL |
| `refused the pull for` | the stored login expired, or its account has no pro access | ask them to run `docker login ghcr.io` again in their own terminal. If the pull fails again, ask them to contact DataSQRL and use open source version (advance agent i.e. adv-agent) |
| anything else | unknown | relay it verbatim and stop |

Leave the token in the user's hands: they set it in their own shell. A token pasted into this conversation would land in your transcript.

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

### 1c. Settle the run choices

A run takes three choices: the harness, the model provider and the model. Settle them once per conversation, before the first run, and remember them for the rest of this conversation; nothing writes them to disk. Read [`reference/agent-setup.md`](reference/agent-setup.md) whenever needed or the user asks about editions, providers, models, variables or AWS, when a check below reports a problem, and when a run fails to start because of a missing variable or an AWS login.

For the run choices, take the source that applies:

1. **The user named them** in this conversation: use those.
2. **An earlier run in this project:** when `.datasqrl_agent_results.json` exists, ask in one line whether to reuse the `harness`, `provider` and `model` of its last run.
3. **Otherwise, ask once.** Run `bash "$CODEAGENT" --show-options` and tell the user the default: the `anthropic` provider, with its default models for planning and implementation. Name the providers it marks `ready`, say that any provider in the list works once its variables are set, and ask which they want.

The user makes each choice: the provider, the model and, for Amazon Bedrock, the AWS profile. Present the options neutrally, without promoting any provider, model or agent.

Then check the choices:

```bash
bash "$CODEAGENT" --check-config [--provider <id>] [--model <model>] [--harness <name>]
```

- For Amazon Bedrock, put `AWS_PROFILE=<name>` in front of `bash` once the user has named the profile, here and on every run command.
- `Status READY`: continue to Step 2.
- `Status NOT READY`: follow the table in [`reference/agent-setup.md`](reference/agent-setup.md#checking-before-a-run), then run the check again. Ask the user to set every key in their own shell, and keep the values out of this conversation.

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

Use the [`requirements` skill](../requirements/SKILL.md). When the user already has a requirements document, use that skill on it. Run its section 4 check and its section 5 hand-off. Planning converts every gap in the requirements into a recorded assumption, so run this stage for a simple-sounding request too.

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

The containerized agent runs its own compile → test → refine loop, plus judges in Lane B. Report the outcome it returns and end the turn. Every outcome (success, review notes, compile failure, test failure, error) is a finished result. Judge issues are review notes on a successful run, not a failure.

The result is the end of the build. The agent does not commit the changes automatically, so the agent's work might be uncommitted in the working tree. After the agent run, express user to observe and review the changes done by agent, and then if the latest changes meet their requirements, tell them that they may commit and push the latest changes to remote remo.
Deploying begins when the user asks for it, as a request of its own.

### Checking on a run

The [`plan`](../plan/SKILL.md), [`implement`](../implement/SKILL.md) and [`patch`](../patch/SKILL.md) skills hand the user the commands to follow the run and start a background `--wait` that tells you when the run ends; the [`progress`](../progress/SKILL.md) skill answers how it is going, explains the progress output, and stops the run when asked.

---

# Deploying to DataSQRL Cloud

DataSQRL Cloud work goes through three skills, and each is a **separate request the user makes**. None needs Docker or the agent image, so invoke the skill directly.

| When the user asks to… | Invoke |
|---|---|
| deploy, ship or release the project; create a deployment | the `deploy` skill |
| check how a deployment is going, read its status or logs | the `deploy` skill |
| sign in to DataSQRL Cloud, or list their organizations or projects | the `deploy` skill |
| make a deployment the project's **main** one — promote it, point production at it | the `promote` skill |
| anything else in DataSQRL Cloud: alerts, metrics, projects, secrets, members; stop, start, resize or terminate a deployment | the `cloud` skill |

Invoke the skill and let it run its own steps; it handles the git checks, the sign-in, the choice of commit and the project lookup itself.

Three conditions keep this section honest:

- **DataSQRL Cloud tools only through these skills.** The DataSQRL Cloud MCP server's own instructions describe the raw API, such as deploying with `POST /api/v1/deployments` or promoting with `runDeploymentAction`. The skills above take precedence: never call a DataSQRL Cloud tool outside the `cloud` skill.

- **Wait to be asked.** This section opens on the user's own request. After a build run, report the result, ask the user to review the changes and tell them they may commit and push, as [After any agent run](#after-any-agent-run) says. The user decides when that code ships, in a request of their own.
- **A deploy never promotes.** Adding a deployment changes nothing about which one is main, so "deploy and ship it" is a deploy, and promoting stays a fresh request. Invoke `promote` only when the user asks for it in its own right, after seeing a deploy result.
