# Data handling and telemetry

This page states what the DataSQRL plugin reads, where data goes, and what stays on your machine.

## In short

- The plugin has no telemetry of its own. Its skills are instructions for your coding agent, and they send data only through the two scripts in `scripts/`.
- The DataSQRL Code Agent runs in a Docker container on your machine. It sends your prompts and project code to the model provider you choose, and to nothing else unless you opt in.
- Telemetry is off by default. With `DATASQRL_TELEMETRY=1`, the run log is uploaded to DataSQRL for troubleshooting.
- `deploy` and `promote` talk to DataSQRL Cloud, and only when you ask for them.

Your coding agent (Claude Code, Codex, Cursor or Copilot) has its own data policy, which this page does not cover.

## What a run can read and write

`scripts/datasqrl-agent.sh` starts the agent container with these mounts:

| Host path | In the container | Access |
|-----------|------------------|--------|
| The git repository around your project | `/workspace` | read-only |
| Your project directory | `/workspace/<project>` | read-write |
| Claude credentials, when you use a Claude login instead of an API key | `/root/.claude/.credentials.json` | read-only |
| Files named by `GOOGLE_APPLICATION_CREDENTIALS`, `AWS_WEB_IDENTITY_TOKEN_FILE`, `AWS_SHARED_CREDENTIALS_FILE`, `AWS_CONFIG_FILE` or `ANTHROPIC_IDENTITY_TOKEN_FILE`, when set | the same path | read-only |
| gcloud Application Default Credentials, for a Vertex run without `GOOGLE_APPLICATION_CREDENTIALS` | `/root/.config/gcloud/` | read-only |

The project directory is the only place a run can write. A run writes these files there:

- `adr/requirements_<ts>.md` and `adr/plan_<ts>.md`, the requirements and the plan.
- `AGENTS.md` and `.claude/`, the agent's instructions, its progress trail and its structured run log (`.claude/codeagent_logs.jsonl.bak`).
- `build/`, the compiler output.
- `.code_agent_results.json`, the run history.
- The DataSQRL project files the agent creates or edits.

## Environment variables

The launcher passes variables into the container by name, and only the names on its `PROVIDER_ENV_VARS` list: the model provider credentials and `DATASQRL_TELEMETRY`. A variable that is unset on your host is skipped, and these values never appear in the `docker run` arguments. To pass more, list their names in `DATASQRL_AGENT_PASS_ENV`.

The launcher also sets these in the container itself:

- `MCP_SERVER_URL`, when you set it.
- `WORKSPACE_DIR`, the project path inside the container.
- `HOST_WORKSPACE_FOLDER`, the name of your project folder (not its full path).
- `HOST_MAC_ID`, the MAC address of your machine's first network interface.

The last two label the run log so that runs from one machine and project can be told apart. They stay in the local log unless you opt in to telemetry.

Everything else in your shell stays outside the container.

## Credentials

- **Model provider.** The coding agent inside the container and its reviewing judges both use the credential of the provider you chose, such as `ANTHROPIC_API_KEY`, `FIREWORKS_API_KEY` or an AWS credential for Amazon Bedrock.
- **Claude login.** Without `ANTHROPIC_API_KEY`, the launcher uses `CLAUDE_CODE_OAUTH_TOKEN`, then `~/.claude/.credentials.json`, then on macOS the Claude Code entry in the Keychain. A token from the variable or the Keychain is written to a temporary file that only your user can read and is mounted read-only. For an attached run the file is deleted when the launcher exits. For a detached run it stays at `${TMPDIR:-/tmp}/datasqrl-agent-creds-<run>.json`, because the container still needs it, and the next run on the same project overwrites it.
- **AWS profile.** For a Bedrock run or an opted-in log upload, `AWS_PROFILE` is turned into one temporary credential on your host and passed in as variables. `~/.aws` is never mounted.
- **Pro edition token.** `DATASQRL_PRO_TOKEN` is sent to `api.github.com` to look up its account and to `ghcr.io` for `docker login`. It is passed on stdin and stays outside the container.
- **DataSQRL Cloud.** `scripts/datasqrl-cloud.sh` signs in with a device-code flow that you approve in a browser. It caches the token in `${XDG_CONFIG_HOME:-~/.config}/datasqrl/credentials.json` with mode `0600`; on Windows NTFS that mode has no effect. `datasqrl-cloud.sh logout` deletes it.

## Network destinations

| Destination | When | What is sent |
|-------------|------|--------------|
| Your model provider | Every run | Prompts, the plan, project files the agent reads, tool output |
| `ghcr.io` | Pulling the agent image | An image pull, and a login for the pro edition |
| `api.github.com` | Pro edition with `DATASQRL_PRO_TOKEN` | The token, to find its account name |
| Your MCP server | Only when `MCP_SERVER_URL` is set | What the agent sends to its tools |
| `s3://datasqrl-debug-logs` | Only with `DATASQRL_TELEMETRY=1` | The run log (see below) |
| `cloud.datasqrl.com`, or `DATASQRL_BASE_URL` | Only `deploy` and `promote` | Sign-in, and the commit, project and deployment ids of the action you asked for |
| `api.github.com` or `gh` | Only `resolve-issue` | A request to read the issue you named |

## Telemetry

Telemetry is opt-in and off by default.

When you set `DATASQRL_TELEMETRY=1` and provide AWS credentials, the run log is uploaded at the end of the run to `s3://datasqrl-debug-logs/<mode>/<request-uuid>_logs.jsonl`. DataSQRL uses it to troubleshoot and debug the agent. The log is the structured record of the run: the agent's messages, its tool calls and their output, test and verification results, and the run result. It can therefore contain excerpts of your code, your test data and command output. Every log entry also carries the run mode, your project folder name and your machine's MAC address.

Without `DATASQRL_TELEMETRY=1`, the log stays in your project, whatever AWS credentials are set. With `DATASQRL_TELEMETRY=1` and incomplete AWS credentials, the run logs a warning and keeps the log local.
