# patch-small-change-runs-patch

Checks that a small, fully determined change goes to the `patch` skill, and that `patch` starts a patch run of the DataSQRL Code Agent.

This case runs with the stub launcher. Run it with [run-stub-launcher-tests.sh](../../../run-stub-launcher-tests.sh), not with `claude plugin eval` on the repository.

## What it tests

- Routing: [Lane A](../../../../../skills/start/SKILL.md#lane-a--patch) of the `start` skill gives "renaming a field" as a typical patch change. The prompt does not name a skill, so the agent must choose `patch` itself.
- The [`patch` skill](../../../../../skills/patch/SKILL.md): it calls `datasqrl-agent.sh` with the user's request and `--mode patch --detach`, waits with `--wait`, and reports the run.

## Setup

`fixture.sh` writes a small DataSQRL project at the root of a new git repository: `orders.sqrl` and `package.json`. `DailyTotals` has a column `total`.

The [stub launcher](../../../stub-launcher/datasqrl-agent.sh) answers every launcher call. It adds each call to `.datasqrl_agent_stub_calls.jsonl`, and the run finishes with success. The case reaches the stub through the plugin copy that `run-stub-launcher-tests.sh` makes, as the [Stub launcher](../../../README.md#stub-launcher) section explains.

## Prompt

`In orders.sqrl, rename the column total to total_amount in DailyTotals. Use the default anthropic provider and its default models.`

The prompt names the provider, so the `start` setup does not stop to ask for one.

## Graders

| Grader | Type | Passes when |
|---|---|---|
| `patch-fired` | `tool_used` | The `patch` skill runs |
| `launcher-called-with-patch` | `regex` on `.datasqrl_agent_stub_calls.jsonl` | One launcher call has the request (`total_amount`), `--mode patch` and `--detach` |
| `no-full-workflow` | `tool_used` | The `requirements`, `plan` and `implement` skills do not run |
| `reports-the-run` | `llm` | The reply gives the run name and says that the patch run finished with success. It does not say that the chat assistant changed `orders.sqrl` with its own tools |

## Run only this case

```bash
tests/claude-plugin-evals/run-stub-launcher-tests.sh --runs 1 --case patch-small-change-runs-patch
```
