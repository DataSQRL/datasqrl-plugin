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
- **Your agent learns when it ends.** Right after the launch, the agent starts `codeagent.sh --wait` in the background. That command waits for the run and prints the result when the run ends, so the agent reports back on its own. You can still ask at any time (`progress`).
- **`progress` works from anywhere** — a different session, hours later, on a run you did not start.
- **One run at a time per project.** A second implement on the same project is refused while the
  first is going, so two agents can never interleave edits to the same files. Different projects
  run in parallel fine.

## Requirements

- **Docker**, running locally. The agent image is fetched and tagged automatically on first use —
  no manual `docker pull` or `docker tag`. If `ghcr.io/datasqrl/code-agent` is private for you, the
  pull will ask you to authenticate with a GitHub token (`read:packages` scope).
- An **Anthropic credential** — an `ANTHROPIC_API_KEY`, or a `claude login` subscription. The
  launcher discovers either automatically.
- **No AWS credentials needed** — the skills pass placeholders, so run-log upload is skipped.
- A **git repository**. The repo is mounted read-only so the agent can discover sibling projects
  and shared data catalogs, and your project is the only writable place.
- **A bash shell.** Every skill shells out to one of the `scripts/*.sh`, so on Windows use
  **WSL**, which is the tested path. Git Bash runs `datasqrl-cloud.sh` but is **not** enough for
  the containerized agent: MSYS rewrites the `-v <host>:/workspace` mount arguments in
  `codeagent.sh`, and `git rev-parse --show-toplevel` yields `/c/Users/…` where Docker Desktop
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

### Claude Code (Local)

```
/plugin marketplace add <absolute path to code-agent/datasqrl-plugin>
/plugin install datasqrl@datasqrl
```

### Claude Code

```
/plugin marketplace add DataSQRL/datasqrl-plugin
/plugin install datasqrl@datasqrl
```

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
`codeagent.sh` by name, so it must be on your `PATH` — the installer tells you how.

## Updating

Claude Code third-party marketplaces don't auto-update by default:

```
/plugin marketplace update datasqrl
/reload-plugins
```

No re-add or reinstall needed. Copilot users re-run `install-skills.sh`.

---

## Maintainers

The source of truth is the `datasqrl-plugin/` directory of
**[DataSQRL/code-agent](https://github.com/DataSQRL/code-agent)**. This repo is **generated** from
it by CI on every merge to `main` — never hand-edit it; open PRs against `code-agent`.

### Layout

The repository root is simultaneously the marketplace root, the plugin root, and the skills tree:

```
.claude-plugin/{marketplace.json, plugin.json}
.codex-plugin/plugin.json
.cursor-plugin/plugin.json
skills/<name>/SKILL.md          ← one shared tree, all three manifests point at it
scripts/codeagent.sh            ← byte-identical copy of agent/codeagent.sh (CI-enforced)
scripts/datasqrl-cloud.sh       ← DataSQRL Cloud API client; lives only here
install-skills.sh               ← Copilot only
```

Flat on purpose: each agent looks for *its own* manifest at the root of whatever repo it is given,
so one published repo installs in all three. The Claude marketplace entry uses `"source": "./"`.

**Do not add a `skills` key to `.claude-plugin/plugin.json`.** With a marketplace-root source, a
declared `skills` list becomes the *complete* set and the default `skills/` scan stops running —
so adding one directory would silently hide all the others. Leaving the key out keeps the full
scan. (That same rule is what would let a second plugin entry carve out its own subset later.)

### Local development

In the source repo, **`agent/codeagent.sh` is canonical** and `scripts/codeagent.sh` is a
byte-identical copy. After editing the launcher:

```bash
./agent/sync-launcher.sh          # refresh the copy
./agent/sync-launcher.sh --check  # what CI runs; non-zero if they differ
```

CI fails the build when they diverge, so the copy cannot drift silently.

**Why a copy and not a symlink.** All three plugin hosts **copy** a plugin into a local cache on
install, and a relative symlink pointing *outside* the plugin directory does not survive that copy —
the installed plugin gets an empty `scripts/` and every skill fails to find the launcher. This
repository shipped a symlink until it was caught, and local installs were silently broken by it.
Do not reintroduce one.

To trial local changes, from your `code-agent` working tree:

```
/plugin marketplace add /absolute/path/to/code-agent/datasqrl-plugin
/plugin install datasqrl@datasqrl
```

After editing a manifest, refresh Claude Code's cached copy:

```
/plugin marketplace update datasqrl
/reload-plugins
```

Edits to a `SKILL.md` take effect immediately — no reload needed.

**Two things that have bitten this plugin before:**

1. **After a stale install, `scripts/` can be empty.** Any plugin cached before the launcher became
   a real file has an empty `scripts/` directory, and every skill fails to find `codeagent.sh`.
   Check the installed copy rather than the source tree:
   ```bash
   ls -l ~/.claude/plugins/cache/datasqrl/datasqrl/*/scripts/
   ```
   If it is empty, reinstall: `/plugin marketplace update datasqrl` then `/reload-plugins`. Old
   caches under a previous plugin name (e.g. `datasqrl-code-agent/0.1.0/`) are worth deleting —
   they hold a launcher predating `--detach`, and a search-based fallback could otherwise find one.
2. **`${CLAUDE_PLUGIN_ROOT}` is a text substitution, not a shell variable.** Claude Code replaces
   the literal `${CLAUDE_PLUGIN_ROOT}` in *skill content* with the plugin's absolute path before the
   model reads it. It is exported as a real environment variable only to hook processes and MCP/LSP
   subprocesses.

   So the skills must use the bare placeholder. Any shell-flavoured variant — `${CLAUDE_PLUGIN_ROOT:+…}`,
   `$CLAUDE_PLUGIN_ROOT` without braces, a default like `${CLAUDE_PLUGIN_ROOT:-…}` — does **not**
   match what Claude Code substitutes, reaches the model unchanged, and then expands to nothing in
   the shell. The symptom is a path starting at `/scripts/...` or a bare `codeagent.sh`, and the
   agent hard-coding an absolute path to recover.

   The second line (`[ -f "$CODEAGENT" ] || CODEAGENT=codeagent.sh`) is what makes the same snippet
   work in Codex/Cursor/Copilot, where the placeholder is never substituted and the launcher comes
   from `PATH`.
