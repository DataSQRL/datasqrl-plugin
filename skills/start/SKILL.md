---
name: start
description: Use whenever the user wants to build, extend, change, or plan a DataSQRL data pipeline or data catalog - including ingesting a source (Kafka topic, webhook, REST endpoint, database, file) into DataSQRL, exposing a GraphQL or REST API over streaming data, or writing a requirements document for such work. Also use when they mention DataSQRL, SQRL, .sqrl files, or ask how to get started with one. This skill owns the whole workflow; it decides what happens next and delegates each step.
---
# Building with DataSQRL

DataSQRL projects are built by a **containerized code agent**, not by you directly. Your job is to
get the user to a good requirements document, drive the agent through plan and implement, and
report what happened. The agent has the SQRL compiler, the DataSQRL skill library, a test runner
and a panel of reviewing judges. You have none of those.

## The one rule

**Never write DataSQRL project files yourself.** Not `.sqrl` scripts, not `*-package.json`, not
GraphQL schemas or operations, not connector configs, not test files or snapshots.

If you write them, they are unreviewed and uncompiled, and the agent will have to reconcile your
guesses with its own work on the next run. Writing a requirements document is your job. Writing the
implementation is not.

The single exception: `adr/requirements_<ts>.md`, which the `requirements` skill writes.

## Make sure the agent image is here

Run this once, at the start. It does nothing when the image is already present:

```bash
if ! docker image inspect datasqrl-code-agent:latest >/dev/null 2>&1; then
  echo "Fetching the DataSQRL agent image..."
  docker pull ghcr.io/datasqrl/code-agent:latest &&
    docker tag ghcr.io/datasqrl/code-agent:latest datasqrl-code-agent:latest
fi
```

**Do not ask permission first, and do not report success.** This is setup for something the user
needed. 

### If it fails

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


## Know where you are, before anything else

Run these two commands from the directory the user wants to build in, and **nothing else**:

```bash
git rev-parse --show-toplevel   # the repository root
git rev-parse --show-prefix     # this project's path inside the repo (empty at the root)
```

These answer the question completely. Do **not** `ls` the project, list its parent, or otherwise
explore the filesystem to work out the layout — git already knows, and guessing from directory
listings is how you end up proposing the wrong repository root.

### If a repository is found

State what you found, in one line, and carry on — this is information, not a gate:

> Building `<prefix>` in the git repository `<toplevel>`. Tell me if that is not the repo you meant.

Say it because the root is occasionally an ancestor nobody intended — a home directory, or a folder
someone ran `git init` in years ago. That does not fail; it silently makes the whole repository
writable and scans all of it into the inventory. Naming it is what gives the user the chance to
catch it.

An empty `--show-prefix` means the project *is* the repository. A non-empty one means it is a
subdirectory, and sibling projects may exist alongside it.

### If no repository is found

No repository means no run can start. Creating one changes the user's filesystem, so ask:

> There is no git repository here. Shall I run `git init` in `<absolute path of cwd>`?

The current directory is the right default; offer the parent instead if the user doesn't specify a path and only says they have a sibling project or shared data catalog this project must read, since those have to live in the
same repository.

### What this means for the run

The repository is bind-mounted, not copied — the agent's writes land directly in the user's real
files. **Launching from the repository root makes the whole repository writable; from a
subdirectory, only that project is**, and everything else is mounted read-only for reference. So if
the user has sibling projects they care about, launching from the project subdirectory is safer.

## The workflow

| Stage | Who does it | Skill |
|-------|-------------|-------|
| 1. Requirements | you, with the user | `requirements` |
| 2. **Review the requirements** | **the user** | — |
| 3. Plan | containerized agent | `plan` |
| 4. **Review the plan** | **the user** | — |
| 5. Implement | containerized agent | `implement` |
| 6. Check on a run | either | `status` |

**Both review stages belong to the user.** Each is a stop, not a formality — you wait for an answer
before moving on.

### Never end a stage silently

Every stage ends one of two ways: with a **question you need answered**, or with an **offer to run
the next stage**. Never with a dead stop that leaves the user guessing what to type.

| After | End with |
|---|---|
| the requirements are written | *"review them — once they look right, tell me and I'll run planning"* |
| the plan is written | *"review it — once it looks right, tell me and I'll run the implementation"* |
| the implementation finishes | nothing. The run is the end of the workflow; report the result and stop. |

Two limits, both of which matter more than the offer itself:

- **The offer never replaces the review.** "Once it looks right, tell me and I'll run it" is an
  invitation to *read the file*. It is not a nudge to skip reading it, and it is not approval you
  can grant on the user's behalf. You still wait.
- **A failed run gets no offer.** Report the failure and stop — no "shall I re-run?", no "want me
  to look into it?". A failure the containerized agent reports is a finished result, and offering
  to chase it is how a clean handoff turns into an unbounded debugging session.

In Claude Code these are `/datasqrl:requirements`, `/datasqrl:plan`, `/datasqrl:implement`,
`/datasqrl:status`. You can also invoke them directly as skills when the user's intent is clear.

### 1. Requirements, and 2. their review

Unless the user already has a requirements document, start here. Use the `requirements` skill.

Do not skip this because the request sounds simple. Planning mode fills every gap with an
assumption and records it; thin requirements do not fail loudly, they produce a confident plan
built on guesses.

That skill ends by listing the open questions and asking the user to review the document. Wait for
their answer — their confirmation is what the `plan` skill treats as approval to proceed. If they
answer open questions in the chat rather than the file, put the answers in the file first; the
planner cannot see this conversation.

### 3. Plan

Use the `plan` skill. It writes `adr/plan_<ts>.md` — a reviewable, checkbox-tracked plan — and
summarizes it. It does not change any project code.

### 4. Review the plan — this stage belongs to the user

Stop and let them read the plan, especially its `## Assumptions` (high-impact ones are tagged) and
its `## Implementation Checklist`. They may edit the file directly before implementing.

Do not critique the plan, rewrite it, or move past this stage on your own initiative.

### 5. Implement

Use the `implement` skill, but only once **all three** of these hold:

1. An `adr/plan_*.md` exists.
2. Its summary was shown to the user in this conversation.
3. The user explicitly approved implementing, in their own words.

**"Build me a DataSQRL pipeline" is approval to start the workflow, not approval to implement.**
If any of the three is missing, say which one, name the command, and stop.

This matters because implementation is a 30-60+ minute containerized run that rewrites project
files. Getting it wrong wastes real time and money.

### 6. Status

`status` reports an in-flight run or the last result, from any session at any time.


## After any agent run

The containerized agent runs its own compile → test → judge → refine loop. A failure it reports is
a **finished result**, not a task handed to you. Do not debug it, do not "fix" the generated code,
and do not propose follow-up work. Report the outcome and stop.

## If the project does not exist yet

The agent creates a new DataSQRL project in an empty directory. There is nothing to scaffold by
hand — do not create `.sqrl` files, a package config, or a directory layout to "get started". Just
confirm the git location as above and run the workflow.
