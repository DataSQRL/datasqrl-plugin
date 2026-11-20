# warehouse-landing-is-a-fit

Checks that the `start` skill says that DataSQRL fits a pipeline that captures changes from a database and lands them in Iceberg for a warehouse. This case is the positive pair of [dbt-models-not-a-fit](../dbt-models-not-a-fit/README.md), so that an agent that sends every warehouse request to dbt fails.

## What it tests

The [Using DataSQRL](../../../../../skills/start/SKILL.md#using-datasqrl) section says that DataSQRL serves results "as tables in a data lake or data warehouse", and that "a typical pipeline takes CDC streams out of a database, enriches them, and lands them in Iceberg, with views generated in the dialect of each query engine".

## Setup

None. The workspace is empty.

## Prompt

`We want to capture the changes from our Postgres orders database, enrich them with customer data, and land the result in Iceberg, so that our analysts can query it from Snowflake. Is DataSQRL a good fit for this? Do not build anything yet.`

## Graders

| Grader | Type | Passes when |
|---|---|---|
| `start-fired` | `tool_used` | The `start` skill runs |
| `is-a-fit` | `llm` | The reply says that DataSQRL fits, and that it lands the data in Iceberg with access from Snowflake |
| `no-build` | `tool_used` | The `requirements`, `plan`, `patch` and `implement` skills do not run |

## Run only this case

```bash
claude plugin eval . --eval-dir tests/claude-plugin-evals/skill-specific-tests --ablation none --runs 1 --case warehouse-landing-is-a-fit
```
