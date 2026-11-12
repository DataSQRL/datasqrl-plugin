# tenant-api-is-a-fit

Checks that the `start` skill says that DataSQRL fits a GraphQL API with access control by JWT claims. This case is the positive pair of [custom-queries-not-a-fit](../custom-queries-not-a-fit/README.md), so that an agent that always answers "no" fails.

## What it tests

The [Using DataSQRL](../../../../../skills/start/SKILL.md#using-datasqrl) section says that DataSQRL serves data "as data APIs (GraphQL, REST, MCP) using JWT tokens and claims for data access control and data filtering or masking."

## Setup

None. The workspace is empty.

## Prompt

`We get order events on a Kafka topic. We want a GraphQL API where each customer sees only their own orders, based on the customer id in their JWT. Is DataSQRL a good fit for this? Do not build anything yet.`

## Graders

| Grader | Type | Passes when |
|---|---|---|
| `start-fired` | `tool_used` | The `start` skill runs |
| `is-a-fit` | `llm` | The reply says that DataSQRL fits, and that it uses JWT claims to filter the API data |
| `no-build` | `tool_used` | The `requirements`, `plan`, `patch` and `implement` skills do not run |

## Run only this case

```bash
claude plugin eval . --eval-dir tests/claude-plugin-evals/skill-specific-tests --ablation none --runs 1 --case tenant-api-is-a-fit
```
