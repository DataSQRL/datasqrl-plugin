# Setting up the DataSQRL Code Agent

Read this when the user asks which edition, provider or model a run uses, how to change them, or what a provider needs, and when `--image-exists`, `--pull-image`, `--check-config` or any run like `--mode planning`, `--mode implementation` reports a problem.

Every command below runs `datasqrl-agent.sh`, the script that starts the agent's container, which the `start` skill locates as `$CODEAGENT`. Each one runs in seconds and starts no build.

## Edition: which image runs

The agent ships as two images. The open-source edition is public, and anyone can pull it. The pro edition is private, and DataSQRL decides who can pull it.

`datasqrl-agent.sh` picks the edition by the first rule that matches:

1. `DATASQRL_AGENT_EDITION=os` or `DATASQRL_AGENT_EDITION=pro`.
2. Pro, when `DATASQRL_PRO_TOKEN` is set.
3. Pro, when the pro image is already on this machine.
4. The open-source edition.

`bash "$CODEAGENT" --image-exists` names the edition it selected and says whether that image is here. `bash "$CODEAGENT" --pull-image` downloads it, about 3GB the first time, or updates it to the newest build.

What each edition needs before its first pull:

| Edition | Requirement | Pull command |
|---|---|---|
| open-source | nothing | `DATASQRL_AGENT_EDITION=os bash "$CODEAGENT" --pull-image` |
| pro, with the token DataSQRL gave the user | the user sets `DATASQRL_PRO_TOKEN` in their shell profile and restarts their coding agent | `bash "$CODEAGENT" --pull-image` |
| pro, with the user's own GitHub account that DataSQRL gave access to | the user logs Docker in to `ghcr.io` once, in their terminal: `echo "$GITHUB_PAT" \| docker login ghcr.io -u <github-username> --password-stdin`, with a personal access token (classic) that has the `read:packages` scope | `DATASQRL_AGENT_EDITION=pro bash "$CODEAGENT" --pull-image` |

Docker keeps that login, so the GitHub account route needs it once per machine. Once the pro image is on the machine, rule 3 selects it on every later command, with no variable set.

## Where settings live

`datasqrl-agent.sh` sees only the environment the user's coding agent started with: the user exports a lasting setting in their shell profile (`~/.zshrc` or `~/.bashrc`) and restarts their coding agent, a name that is not a secret can prefix one command (`AWS_PROFILE=dev bash "$CODEAGENT" …`), and keys stay in the user's own shell, out of this conversation.

## Harness, provider and model

```bash
bash "$CODEAGENT" --show-options
```

This prints what the selected image offers: its harnesses and the default one, the default provider, the default model for each mode, and every provider with the variables it needs and whether each is set. It never prints a value.

- **Default:** the `anthropic` provider, with `claude-opus-5` for planning and `claude-sonnet-5` for implementation and patch. It needs `ANTHROPIC_API_KEY`.
- **Choose for one run:** add `--provider <id>` and `--model <model>` to the run command, and `--harness <name>` for a harness other than the default.
- **Choose for every run:** the user exports `DATASQRL_AGENT_PROVIDER` and `DATASQRL_AGENT_MODEL`. They apply to every mode, planning included, so the planning default model gives way to the one chosen.
- **A provider other than `anthropic` needs `--model`.** The default models are Anthropic model ids. Give the model id exactly as the provider lists it.
- **The judges that review the work run on the same provider and model,** so the chosen provider's variables are the only credential a run needs.

## Passing the run choices

Every run command and every `--check-config` takes the same run choices: the `--provider`, `--model` and `--harness` flags the user settled. A provider that needs a setting on each command says so in its own section below, such as the AWS profile for [Amazon Bedrock](#amazon-bedrock). With nothing settled, add nothing: the run uses the defaults.

## What one provider needs

```bash
bash "$CODEAGENT" --show-options <provider-id>
bash "$CODEAGENT" --show-options <provider-id> --harness <name>
```

This prints the variable sets the provider accepts, and for each variable whether it is set. One complete set is enough. Relay the variable names to the user, with where to set them from [Where settings live](#where-settings-live).

## Checking before a run

```bash
bash "$CODEAGENT" --check-config [--provider <id>] [--model <model>] [--harness <name>]
```

Give it the same choices the run will take. Without flags it uses `DATASQRL_AGENT_PROVIDER` and `DATASQRL_AGENT_MODEL`, as a run does. It ends with `Status READY` (exit 0) or `Status NOT READY` (exit 1).

| It shows | What to do |
|---|---|
| `<NAME> missing` | ask the user to set that variable in their shell profile and restart their coding agent |
| `Error: --provider <id> needs --model` | ask which model of that provider to use, then pass it with `--model` |
| `Error: Provider '<id>' is not in the provider list` | the selected harness takes other providers; run `--show-options` and ask the user to choose one of them |
| a line starting with `→` | follow it; it names the command or the question for the user |
| `Status READY` | continue |

## Amazon Bedrock

A Bedrock run uses an AWS profile, or AWS access keys. With a profile, `datasqrl-agent.sh` turns it into one temporary credential on this machine, so the user's `~/.aws` stays on their machine. Access keys set in the shell take precedence over a profile.

- **Which profile:** with no `AWS_PROFILE` and no access keys set, `--check-config --provider amazon-bedrock --model <model>` lists the profiles on this machine with their account, role and region. `aws configure list-profiles` prints the names alone. Many users keep several profiles for different work, so ask which one is for DataSQRL. Pass the answer as a prefix, `AWS_PROFILE=<name> bash "$CODEAGENT" …`, on `--check-config` and on every run command. To keep it, the user exports it in their shell profile.
- **SSO login:** an SSO login lasts some hours. When it has expired, `--check-config` says so and names the command. The login opens a browser, so the user runs it themselves, in their terminal: `aws sso login --profile <name>`. In Claude Code they can type `! aws sso login --profile <name>` in the prompt.
- **Region:** `AWS_REGION` when set, else the profile's region, else `us-east-1`. Choose a region where the account has access to the model.
- **Model ids** on Bedrock carry the Bedrock form, for example `us.anthropic.claude-opus-5-5`.
- The profile needs the AWS CLI v2 on this machine.

## Telemetry

The run log stays in the project. With `DATASQRL_TELEMETRY=1` and AWS credentials, the agent uploads it to DataSQRL for troubleshooting. It is off unless the user opts in.
