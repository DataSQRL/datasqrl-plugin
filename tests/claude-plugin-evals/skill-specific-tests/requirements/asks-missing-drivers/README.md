# requirements-asks-missing-drivers

Checks that the `requirements` skill asks the user about the [architecture drivers](../../../../../skills/requirements/SKILL.md#architecture-drivers) that the user's notes leave out.

## What it tests

[Section 1](../../../../../skills/requirements/SKILL.md#1-gather-before-you-write) of the `requirements` skill tells the agent to ask the user about "workload and budget, who may access the results". This case checks that the agent asks about these drivers, and that it does not ask again for facts that the notes give.

## Setup

`fixture.sh` writes `notes.md` into a new git repository. The notes give:

- the source: the Kafka topic `orders`, with a sample record
- the result: a GraphQL API with the daily order total for each customer
- the freshness: 5 minutes

The notes leave out the workload, the budget, the reliability, the API latency and who may access the results.

## Prompt

`/datasqrl:requirements Build the pipeline that notes.md describes.`

The prompt loads the skill directly, as [Starting a prompt with `/datasqrl:<skill-name>`](../../../README.md#starting-a-prompt-with-datasqrlskill-name) explains. The case has no `Write` tool, so the run ends at the agent's first questions.

## Graders

| Grader | Type | Passes when |
|---|---|---|
| `asks-missing-drivers` | `llm` | The reply asks about the volume, the budget and the access. It does not ask again for the topic or the freshness |
| `no-plan` | `tool_used` | The `plan` skill does not run |

## Run only this case

```bash
claude plugin eval . --eval-dir tests/claude-plugin-evals/skill-specific-tests --scaffold --ablation none --runs 1 --case requirements-asks-missing-drivers
```
