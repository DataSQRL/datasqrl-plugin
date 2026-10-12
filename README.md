# DataSQRL for coding agents

Build [DataSQRL](https://datasqrl.com) data pipelines from your coding agent, using the Dockerized
**DataSQRL Code Agent**.

Installs as a plugin in **Claude Code**, **Codex** and **Cursor**; copies in as skills for
**GitHub Copilot**.

## What it does

You describe what you want in plain English. Your agent turns that into a proper requirements
document, hands it to the containerized DataSQRL agent to plan, waits for you to review the plan,
then runs the autonomous implement → compile → test → verify → refine loop.

For a small change to a project that already exists, that whole workflow is overkill — `patch`
sends the request straight to the implementing agent instead.

Your agent never writes SQRL itself — the container has the compiler, the DataSQRL skill library,
the test runner and the reviewing judges.

| Skill | Claude Code | What it does |
|-------|-------------|--------------|
| `start` | `/datasqrl:start` | The workflow. Usually loads by itself when you describe pipeline work. |
| `requirements` | `/datasqrl:requirements` | Gathers and writes `adr/requirements_<ts>.md`. |
| `plan` | `/datasqrl:plan` | Planning run → reviewable, checkbox-tracked `adr/plan_<ts>.md`. |
| `implement` | `/datasqrl:implement` | The full autonomous loop over an approved plan. |
| `patch` | `/datasqrl:patch` | A small change to an existing project: no planning, no judges, but it still runs and fixes the tests. |
| `resolve-issue` | `/datasqrl:resolve-issue` | Resolves a GitHub issue, such as one the DataSQRL Cloud assistant filed: runs the agent from the project's directory in the lane the fix needs, then gives you the commit message that closes the issue. |
| `progress` | `/datasqrl:progress` | Everything about the current run: is it still going, what its progress output means, whether it is stuck; stops it on request. |
| `deploy` | `/datasqrl:deploy` | Deploys a committed and pushed project to DataSQRL Cloud, waits for it, reports the result. Also reads deployment status and logs. |
| `promote` | `/datasqrl:promote` | Makes an existing deployment the project's main one, after showing you which one it replaces. |

`deploy` is a separate step you ask for, not the tail of an implementation run. It deploys a
commit from GitHub rather than your working tree, so the work has to be committed and pushed
first, and signing in needs you to approve a browser prompt once per session. Terminating,
stopping, resizing and upgrading deployments, and managing projects, members and secrets, are
Web UI tasks — neither skill can do them.

`promote` is deliberately separate from `deploy`, and never chained onto it. Deploying adds a new
deployment and changes nothing about which one is main; promoting changes what the project serves.
So the second is always its own request, made after you have seen the first one succeed.

You rarely type any of these. Say *"I want a pipeline that ingests our order webhooks and reports
daily revenue"* and the workflow starts on its own.

## Runs are detached

An implementation run takes 30–60+ minutes, far longer than a coding agent may hold a foreground
command open. Runs are therefore started **detached** and the launch returns in about two seconds.
The run belongs to the Docker daemon, not to your session, which means:

- **Close the session, interrupt your agent, reboot your editor** — the run finishes anyway and
  still writes `.code_agent_results.json`.
- **You follow it from another terminal.** The launch prints the command, `tail -f` on the run's progress log, that shows what the agent is doing as it happens. Ask your agent whether it is still going, what the output means, or to stop it (`progress`).
- **Your agent learns when it ends.** Right after the launch, the agent starts `datasqrl-agent.sh --wait` in the background. That command waits for the run and prints the result when the run ends, so the agent reports back on its own. You can still ask at any time (`progress`).
- **`progress` works from anywhere** — a different session, hours later, on a run you did not start.
- **One run at a time per project.** A second implement on the same project is refused while the
  first is going, so two agents can never interleave edits to the same files. Different projects
  run in parallel fine.

## Requirements

- **Docker**, running locally. The agent image is fetched and tagged automatically on first use,
  with no manual `docker pull` or `docker tag`. It is the open-source edition, which anyone can
  pull. For the pro edition, set `DATASQRL_PRO_TOKEN` in the shell that starts your coding agent
  to the token DataSQRL gave you. If DataSQRL has given your own GitHub account access to the pro
  edition, a personal access token (classic) from that account with the `read:packages` scope
  works the same way. The launcher then logs in and pulls pro. Set the token in your shell, not in
  the chat with your coding agent.
- A **model provider credential**: `ANTHROPIC_API_KEY` for the default provider, or the variables of the provider you choose, such as `FIREWORKS_API_KEY` or an AWS profile for Amazon Bedrock. Set them in the shell that starts your coding agent, not in the chat with it. `datasqrl-agent.sh --show-options` lists the providers and what each needs, and `datasqrl-agent.sh --check-config` tells you whether a run is ready. Your coding agent runs both for you during setup; [`skills/start/reference/agent-setup.md`](skills/start/reference/agent-setup.md) explains them.
- **AWS credentials only for Amazon Bedrock.** The run log stays in your project. Telemetry is off by default; opt in with `DATASQRL_TELEMETRY=1` and AWS keys, which shares it with DataSQRL for troubleshooting and debugging.
- A **git repository**. The repo is mounted read-only so the agent can discover sibling projects
  and shared data catalogs, and your project is the only writable place.
- **A bash shell.** Every skill shells out to one of the `scripts/*.sh`, so on Windows use
  **WSL**, which is the tested path. Git Bash runs `datasqrl-cloud.sh` but is **not** enough for
  the containerized agent: MSYS rewrites the `-v <host>:/workspace` mount arguments in
  `datasqrl-agent.sh`, and `git rev-parse --show-toplevel` yields `/c/Users/…` where Docker Desktop
  wants `C:/Users/…`.

For `resolve-issue` only:

- **`gh`**, signed in (`gh auth login`), to read the issue. A public repository's issue also
  reads with `curl` and `jq`.

For `deploy` and `promote` only:

- **`curl` and `jq`** on your PATH. Git Bash ships `curl` but not `jq`: `winget install jq`.
  On NTFS the token cache cannot be permission-restricted, so it is only as private as your user
  profile directory.
- A **DataSQRL Cloud account** with the Member or Owner role in the organization, and the project
  already created there (Add Project links it to a GitHub repository).
- A **browser**, to approve the sign-in. Tokens are cached under
  `${XDG_CONFIG_HOME:-~/.config}/datasqrl/credentials.json` and refresh themselves, so this is at
  most once per session.

## Install

### Claude Code

```
/plugin marketplace add DataSQRL/datasqrl-plugin
/plugin install datasqrl@datasqrl
```

To install from a local clone instead, pass its absolute path to `marketplace add`.

### Codex

```
codex plugin marketplace add DataSQRL/datasqrl-plugin
```

### Cursor

Point Cursor at `DataSQRL/datasqrl-plugin`; the manifest is at the repository root.

### GitHub Copilot

Copilot has no plugin system — it reads skills from directories inside the repository you are
working in. Clone this repo and run the installer against your project:

```bash
git clone https://github.com/DataSQRL/datasqrl-plugin
./datasqrl-plugin/install-skills.sh /path/to/your/repo
```

That copies the skills into `.github/skills/` and `.agents/skills/`. The skills invoke
`datasqrl-agent.sh` by name, so it must be on your `PATH`. Every release attaches the launcher, and
this installs the latest one:

```bash
curl -fsSL https://github.com/DataSQRL/datasqrl-plugin/releases/latest/download/datasqrl-agent.sh \
  -o /usr/local/bin/datasqrl-agent.sh && chmod +x /usr/local/bin/datasqrl-agent.sh
```

## Updating

Claude Code third-party marketplaces don't auto-update by default:

```
/plugin marketplace update datasqrl
/reload-plugins
```

No re-add or reinstall needed. Copilot users pull this repository, re-run `install-skills.sh`,
and download the launcher again. [Releases](https://github.com/DataSQRL/datasqrl-plugin/releases)
lists what changed in each version.

## Data handling and telemetry

The plugin has no telemetry of its own, and the agent's telemetry is off by default. A run sends
your prompts and project code to the model provider you choose; `deploy` and `promote` talk to
DataSQRL Cloud.
[DATA_HANDLING.md](DATA_HANDLING.md) lists what runs where, which credentials are read, and what
leaves your machine.

## Contributing

Issues and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers how to test a
change locally and the checks CI runs.
Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
