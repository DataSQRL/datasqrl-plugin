# custom-queries-not-a-fit

Checks that the `start` skill says that DataSQRL does not run ad hoc queries.

## What it tests

The [Using DataSQRL](../../../../../skills/start/SKILL.md#using-datasqrl) section says that custom queries are not a good fit: "DataSQRL builds the tables and datasets those queries target but does not execute the queries themselves." This case checks that the agent gives this answer, and that it does not start a build.

## Setup

None. The workspace is empty.

## Prompt

`Our analysts want to write their own SQL queries against our order data, whenever they like. Can DataSQRL do that for us?`

The prompt does not name a skill, so the case also checks that the `start` skill fires on a question about DataSQRL.

## Graders

| Grader | Type | Passes when |
|---|---|---|
| `start-fired` | `tool_used` | The `start` skill runs |
| `not-a-fit` | `llm` | The reply says that DataSQRL does not run ad hoc queries, and points to a data warehouse or a query engine |
| `no-build` | `tool_used` | The `requirements`, `plan`, `patch` and `implement` skills do not run |

## Run only this case

```bash
claude plugin eval . --eval-dir tests/claude-plugin-evals/skill-specific-tests --ablation none --runs 1 --case custom-queries-not-a-fit
```
