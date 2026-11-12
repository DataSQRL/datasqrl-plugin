# Claude plugin evals

These cases run Claude Code with this plugin loaded, and grade what the skills do. Each run calls the model, so each run costs tokens. Run them by hand, not in CI.

The cases are in two eval folders, and each folder has its own command:

| Eval folder | Plugin under test | Command |
|---|---|---|
| `skill-specific-tests/` | This repository as it is. Use it to test the skill steps that do not need the launcher. The real `scripts/datasqrl-agent.sh` cannot run in an eval run, because it needs Docker (see [Why the real scripts cannot run](#why-the-real-scripts-cannot-run)) | `claude plugin eval . --eval-dir tests/claude-plugin-evals/skill-specific-tests ...` |
| `stub-launcher-tests/` | A temporary copy of this repository, with the [stub launcher](#stub-launcher) in place of `scripts/datasqrl-agent.sh` | `tests/claude-plugin-evals/run-stub-launcher-tests.sh ...` |

Run every case in `skill-specific-tests/` from the repository root:

```bash
claude plugin eval . --eval-dir tests/claude-plugin-evals/skill-specific-tests --scaffold --ablation none --allow-tools Write --threshold 0.8
```

Run one case once, while you write or change it:

```bash
claude plugin eval . --eval-dir tests/claude-plugin-evals/skill-specific-tests --scaffold --ablation none --allow-tools Write --runs 1 --case requirements-asks-missing-drivers
```

- `--scaffold` runs each case's `fixture.sh`, which writes the case's files into an empty git repository.
- `--ablation none` runs each case with the plugin only. It skips the runs without the plugin, which halves the cost.
- `--allow-tools Write` lets the test to write file. Useful if expected output is a file. Example: `requirements` skill write `adr/requirements_<timestamp>.md`.
- `--threshold 0.8` lets a case pass when 80% of its grader checks pass. The default is 1.0.
- Results go to `tests/claude-plugin-evals/skill-specific-tests/results/<timestamp>/`.

Run every case in `stub-launcher-tests/`, from any folder:

```bash
tests/claude-plugin-evals/run-stub-launcher-tests.sh --threshold 0.8
```

The script passes its arguments to `claude plugin eval`, so `--runs 1 --case <name>` also works. It always adds `--scaffold`, `--ablation none` and `--allow-tools Bash`. Results go to `tests/claude-plugin-evals/stub-launcher-tests/results/<timestamp>/`.

## Folder layout

```
tests/claude-plugin-evals/
├── README.md
├── skill-specific-tests/            # eval folder: cases on the real plugin
│   ├── requirements/                # cases for skills/requirements
│   │   └── <case>/
│   │       ├── README.md            # what the case tests, for people
│   │       ├── case.yaml            # case name, tags, scaffold script
│   │       ├── fixture.sh           # writes the workspace files before the run
│   │       ├── prompt.md            # the user message and the run limits
│   │       └── graders/             # one file for each check
│   ├── start/                       # cases for skills/start
│   └── results/                     # written by each run, in .gitignore
├── stub-launcher-tests/             # eval folder: cases on a plugin copy with the stub launcher
│   ├── patch/                       # cases for skills/patch
│   └── results/                     # written by each run, in .gitignore
├── stub-launcher/
│   └── datasqrl-agent.sh            # the stub launcher
└── run-stub-launcher-tests.sh       # copies the plugin, puts the stub in, runs the cases
```

`claude plugin eval` finds every folder that has a `prompt.md` or a `case.yaml`, at any depth below the eval folder. The folders above the case folders only group the cases. The two eval folders keep the stub cases out of the run on the real plugin, where they fail.

## Case files

A case folder holds these files. `claude plugin eval` reads `prompt.md`, `case.yaml` and `graders/`. It does not read `README.md`.

### `prompt.md`

The body is the user message. The frontmatter sets how the case runs. The most useful fields:

| Field | Default | Purpose |
|---|---|---|
| `max_turns` | `10` | The maximum number of agent turns in a run |
| `timeout_seconds` | `300` | The maximum time of a run |
| `allowed_tools` | `[]` | The tools that the case uses. A tool other than `Read`, `Glob`, `Grep`, `Skill` and a few other read-only tools also needs `--allow-tools` on the command line |
| `runs` | `3` | The number of runs. `--runs` on the command line overrides it |
| `tags` | `[]` | Labels for `--tag`, which runs only the cases with that tag |
| `description` | none | A note for people. The run does not use it |

### `case.yaml`

`case.yaml` is optional. Add it when the case needs a field that `prompt.md` cannot hold. These fields exist only in `case.yaml`:

| Field | Purpose |
|---|---|
| `context.scaffold_script` | A Bash script in the case folder. It runs in the empty workspace before the agent starts, and only with `--scaffold`. Use it to write files and make a git repository |
| `context.history_file` | A `.jsonl` file with an earlier conversation. The run continues that conversation, and the prompt becomes the next user message. Use it to test the agent's answer to a user reply |
| `context.add_dirs` | Folders in the case folder that the agent can read during the run, but not change |
| `graders` | A list of graders, as an alternative to the files in `graders/` |
| `execution.prompt` | The prompt, when the case has no `prompt.md` |

`case.yaml` needs `schema_version: "1.1"` and `name`. The `name` is the case name for `--case`. A case with only a `prompt.md` takes its folder name as its case name. Example from [asks-missing-drivers](skill-specific-tests/requirements/asks-missing-drivers/case.yaml):

```yaml
schema_version: "1.1"
name: requirements-asks-missing-drivers
description: The notes give the sources, results and freshness. The requirements skill asks about the drivers that the notes leave out.
tags: [requirements]
context:
  scaffold_script: fixture.sh
```

The cases in `skill-specific-tests/start/` need no files, so they have no `case.yaml`.

### `fixture.sh`

The script that `context.scaffold_script` names. It runs as you, outside the sandbox, with a limit of 120 seconds. A non-zero exit fails the run. Make it executable.

### `graders/`

One file for each check. The frontmatter sets the grader type and its options. For an `llm` grader, the body is the rubric. [What a grader sees](#what-a-grader-sees) tells which part of the run each type reads.

## Cases

Each case folder has a `README.md` with the setup, the prompt, the graders and the command that runs only that case.

| Case | What it checks |
|---|---|
| [requirements/asks-missing-drivers](skill-specific-tests/requirements/asks-missing-drivers/README.md) | The skill asks about the architecture drivers that the notes leave out: workload, budget and authorization |
| [requirements/hand-off-lists-open-questions](skill-specific-tests/requirements/hand-off-lists-open-questions/README.md) | The skill writes the file with the template sections, lists the open questions with a default for each, and waits |
| [requirements/pushes-back-on-realtime](skill-specific-tests/requirements/pushes-back-on-realtime/README.md) | The skill asks what staleness is acceptable before it accepts "realtime" |
| [requirements/confirms-hard-constraints](skill-specific-tests/requirements/confirms-hard-constraints/README.md) | The skill keeps the user's GraphQL query, and records Postgres as an open question, not as a hard constraint |
| [requirements/records-user-hard-constraint](skill-specific-tests/requirements/records-user-hard-constraint/README.md) | The skill writes the model that the user requires under `## Hard constraints`, with the user's reason |
| [start/custom-queries-not-a-fit](skill-specific-tests/start/custom-queries-not-a-fit/README.md) | The skill says that DataSQRL does not run ad hoc queries |
| [start/tenant-api-is-a-fit](skill-specific-tests/start/tenant-api-is-a-fit/README.md) | The skill says that DataSQRL fits a per-customer API with JWT claims |
| [patch/small-change-runs-patch](stub-launcher-tests/patch/small-change-runs-patch/README.md) (stub launcher) | A small change goes to the `patch` skill, which calls the launcher with `--mode patch --detach` and reports the run |

## Starting a prompt with `/datasqrl:<skill-name>`

In tests, a prompt can start with `/datasqrl:<skill-name>`, for example `/datasqrl:requirements`. This slash command loads that skill directly. The agent does not choose a skill from the skill descriptions, and no other skill runs first.

Start the prompt this way when the case tests what one skill does:

- **The case tests the skill, not the choice of skill.** Every run uses the same skill. A failure points to the skill text, not to the routing.
- **The case skips the steps of other skills.** For example, a build request goes to the `start` skill first. `start` runs a setup with Bash commands (`datasqrl-agent.sh --image-exists`, `git rev-parse`) and asks for a model provider. Without Bash, a run that goes through `start` stops in that setup. With Bash and a stub launcher, the setup passes (see [Bash in a run](#bash-in-a-run)).
- **The run is shorter and costs less.** The agent does not read the `start` skill.

Write the prompt without the slash command when the case tests the choice of skill. Then add a `tool_used` grader for the `Skill` tool, to check that the correct skill runs.

Example of a prompt with the slash command, from [asks-missing-drivers](skill-specific-tests/requirements/asks-missing-drivers/prompt.md). The case tests what the `requirements` skill asks:

```
/datasqrl:requirements Build the pipeline that notes.md describes.
```

Example of a prompt without the slash command, from [custom-queries-not-a-fit](skill-specific-tests/start/custom-queries-not-a-fit/prompt.md). The case also tests that the agent chooses the `start` skill, with the `start-fired` grader:

```
Our analysts want to write their own SQL queries against our order data, whenever they like. Can DataSQRL do that for us?
```

## How to write a case

1. Read the [plugin evals documentation](https://code.claude.com/docs/en/plugin-evals). It is the full reference for the case files, the grader types and the command options.
2. Make a folder under `skill-specific-tests/<skill>/<case-name>/`. Use a name that says what the agent must do, for example `asks-missing-drivers`. When the case needs the launcher, make it under `stub-launcher-tests/<skill>/<case-name>/` instead.
3. Write `prompt.md`. The body is the user message. Write it as a user types it. The frontmatter sets the run limits and the tools:

   ```markdown
   ---
   max_turns: 20
   allowed_tools: [Read, Glob, Grep, Skill]
   ---

   /datasqrl:requirements Build the pipeline that notes.md describes.
   ```

   The run allows only the read-only tools in `allowed_tools`. A tool such as `Write` also needs `--allow-tools Write` on the command line.
4. When the agent needs files, write `case.yaml` and `fixture.sh`, as [Case files](#case-files) describes. Each run starts in an empty folder, and `fixture.sh` writes the files into it.

   Make `fixture.sh` executable. Each run has a new, empty home folder, so git has no user name and no email there. Without them, `git commit` stops with an error. Give both values in the commit command:

   ```bash
   git -c user.name=eval -c user.email=eval@example.com commit -q -m "notes"
   ```
5. Write one file in `graders/` for each check. These types are the most useful for this plugin:

   | Type | Use it to check | Example |
   |---|---|---|
   | `llm` | What the reply says. The file body is the rubric, with concrete PASS and FAIL lines | [asks-missing-drivers.md](skill-specific-tests/requirements/asks-missing-drivers/graders/asks-missing-drivers.md) |
   | `tool_used` | That a skill or tool runs, or does not run (`min: 0`, `max: 0`) | [no-plan.md](skill-specific-tests/requirements/asks-missing-drivers/graders/no-plan.md) |
   | `tool_used` with `input_match` | What the agent writes into a file. The regex runs on the JSON input of the `Write` call | [template-sections.md](skill-specific-tests/requirements/hand-off-lists-open-questions/graders/template-sections.md) |
   | `file_exists` | That the run creates a file. `path` takes a glob | [file-written.md](skill-specific-tests/requirements/hand-off-lists-open-questions/graders/file-written.md) |

   Give each case one grader on the result and one on the steps, for example an `llm` grader on the reply and a `tool_used` grader on the skills. [What a grader sees](#what-a-grader-sees) tells which part of the run each grader reads.
6. Write a `README.md` for the case: what it tests, the setup, the prompt, the graders, and the command that runs only that case.
7. Run the case once with `--runs 1 --case <name>`. When a grader fails, read what the agent did:
   - `results/<timestamp>/aggregate-result.json` has an `evidence` field for each `llm` grader. It holds the reply that the judge read.
   - For every tool call, run again with `--keep-temp`. The run prints the folder that it keeps. The full run is in `out/trace.jsonl` in that folder.

   Then decide if the skill or the grader is wrong.
8. Add the case to the table in this README.

## What a grader sees

A run is one user message. To answer it, the agent takes one or more turns. In each turn, it calls tools or writes text. The run ends when the agent stops, for example at a question to the user, or at `max_turns`. The graders check the run after it ends.

| Grader | What it sees |
|---|---|
| `llm` | By default, only the last reply of the agent. With `focus: trace`, the first 12 and the last 12 messages of the run. With `focus: { source: file, path: <path> }`, one file after the run |
| `tool_used` | Every call to the tool in the run, in all turns. It counts the calls whose JSON input matches `input_match`, and passes when the count is between `min` and `max` |
| `tool_order` | Every tool call in the run. It compares the first matching call of each of two tools |
| `regex` | By default, only the last reply. With `target: trace`, every message of the run |
| `file_exists` | The files that the agent creates during the run. Files from `fixture.sh` do not count |

Examples from this suite:

- `asks-missing-drivers` is an `llm` grader. It reads only the last reply, which holds the questions to the user.
- `no-plan` is a `tool_used` grader. It checks every `Skill` call in the run, and passes when no call loads the `plan` skill.
- `template-sections` is a `tool_used` grader. It checks every `Write` call in the run. A `Write` call holds the full file text, so the grader can check the sections of a file whose name it does not know.

## Bash in a run

A case can use Bash. List `Bash` in `allowed_tools`, and pass `--allow-tools Bash` on the command line. Bash then runs in the Claude Code sandbox. These results come from test runs on macOS on 2026-11-12:

| Command | Result in the sandbox |
|---|---|
| `date` | Works, so the agent can read the clock |
| `ls` and `bash` on the plugin folder | Work. The loaded skill text has the full path of the plugin, so `datasqrl-agent.sh` starts |
| `docker` | Fails. The sandbox blocks `/var/run/docker.sock`, and `datasqrl-agent.sh` stops with "cannot talk to the Docker daemon" |
| `git` (the macOS `/usr/bin/git`) | Fails. It cannot write its cache file. A `git` wrapper at the start of your `PATH` does not help, because the Bash shell in the run still finds `/usr/bin/git` |
| `git init` | Fails. The sandbox blocks writes to `.git` |
| `curl` to a website | Fails. The network is blocked, except for the domains that you grant with `--allow-tools "WebFetch(domain:<domain>)"` |

### Why the real scripts cannot run

The skills reach Docker and DataSQRL Cloud only through two scripts, and the sandbox blocks what each script needs:

| Skills | Script | What the script needs | Why it fails in a run |
|---|---|---|---|
| `start` (setup), `plan`, `implement`, `patch`, `resolve-issue` | `datasqrl-agent.sh` | Docker: `docker image inspect` for the image check, `docker run` to start the agent container | The sandbox blocks `/var/run/docker.sock`. The Claude Code sandbox documentation says that `docker` does not work in the sandbox |
| `deploy`, `promote` | `datasqrl-cloud.sh` | The network, to call `https://cloud.datasqrl.com`. A login token in `~/.config/datasqrl/credentials.json` | The sandbox blocks the network. The run has a new, empty home folder, so there is no token |

So with the real scripts, a run of these skills stops at the first script call.

### Stub launcher

The [stub launcher](stub-launcher/datasqrl-agent.sh) removes this limit for `datasqrl-agent.sh`. It starts no container. It does three things:

1. For each call, it adds one line to `.datasqrl_agent_stub_calls.jsonl` in the working folder, for example `{"arguments": ["rename the column", "--mode", "patch", "--detach"]}`. The real launcher writes no such file. Graders read it to check the launcher calls.
2. It prints the answer that the real launcher prints: the image line for `--image-exists`, a provider list for `--show-options`, `Status READY` for `--check-config`, a run name for `--detach`, and a `Finished · success` line for `--wait` and `--status`.
3. For `--detach`, it writes `.datasqrl_agent_results.json`, as the agent container does at the end of a run.

[run-stub-launcher-tests.sh](run-stub-launcher-tests.sh) runs the cases in `stub-launcher-tests/` with the stub:

1. It copies the plugin to a temporary folder, without `.git` and the `results/` folders.
2. In the copy, it replaces `scripts/datasqrl-agent.sh` with the stub.
3. It runs `claude plugin eval` on the copy, with `--allow-tools Bash`.
4. It deletes the copy at the end. The results stay in `stub-launcher-tests/results/`.

A case in `stub-launcher-tests/` does not name the stub anywhere. The case reaches the stub in this order:

1. `claude plugin eval` loads the plugin from the copy, so `CLAUDE_PLUGIN_ROOT` is the folder of the copy.
2. The skill text has the line `CODEAGENT="${CLAUDE_PLUGIN_ROOT}/scripts/datasqrl-agent.sh"`. When the skill loads, Claude Code puts the full path of the copy in its place.
3. The agent runs `bash "$CODEAGENT" ...` with Bash. That path is `scripts/datasqrl-agent.sh` in the copy, which is the stub.

For the same reason, a copy is necessary. A stub on `PATH` is not used, because the skills call the launcher by its full path. And the real `scripts/datasqrl-agent.sh` in this repository must not change.

To check the launcher calls, use a `regex` grader on the call file. Example from [small-change-runs-patch](stub-launcher-tests/patch/small-change-runs-patch/graders/launcher-called-with-patch.md):

```markdown
---
type: regex
target: { source: file, path: .datasqrl_agent_stub_calls.jsonl }
pattern: 'total_amount.*("--mode", "patch"|"--mode=patch").*"--detach"'
---
```

The path is relative to the workspace. The skills run the launcher in the project folder, so put the project at the root of the workspace, or add the project folder to the path.

In a test run, a build request also went through the full `start` setup on the stub: `--image-exists`, then `--check-config`, then the `requirements` skill.

Three facts to know before you write a case with Bash:

- **The agent can write files with Bash.** In a test run, it wrote the requirements file with `cat > ... <<EOF`, not with the `Write` tool. A `tool_used` grader on `Write` misses that file.
- **`git rev-parse` fails on macOS**, as the table above shows. `start` continued without it in the test run.
- **Name the model provider in the prompt.** Otherwise the `start` setup asks the user for one, and the run ends at that question.

A stub for `datasqrl-cloud.sh` would need canned answers for each DataSQRL Cloud call. Nobody has written one yet.

## Limits

- **No Docker and no network.** The sandbox blocks both. The [stub launcher](#stub-launcher) covers the skills that call `datasqrl-agent.sh`, but it does not test the Code Agent itself. No case covers `deploy` and `promote`. See [Bash in a run](#bash-in-a-run).
- **One user message.** A run ends at the first question to the user, and the graders grade that question. A case that needs the user's answer needs a recorded conversation in `context.history_file`.
- **No clock.** The cases do not grant Bash, so the agent cannot read the time. The time in `requirements_<timestamp>.md` is a placeholder.
- **Different results between runs.** An `llm` judge votes three times, and the agent's reply changes from run to run. Use `--threshold 0.8` and 3 runs for each case.
