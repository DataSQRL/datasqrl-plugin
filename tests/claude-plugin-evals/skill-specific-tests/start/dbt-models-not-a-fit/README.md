# dbt-models-not-a-fit

Checks that the `start` skill says that scheduled models inside a warehouse belong in dbt or SQLMesh. This case is the negative pair of [warehouse-landing-is-a-fit](../warehouse-landing-is-a-fit/README.md): the two cases together fix the boundary between analytics engineering and operational data engineering.

## What it tests

The [Using DataSQRL](../../../../../skills/start/SKILL.md#using-datasqrl) section lists analytics engineering inside a warehouse as not a good fit: "models that run on a schedule inside Snowflake, BigQuery, or Databricks and build tables for dashboards, reports, and BI belong in dbt or SQLMesh." This case checks that the agent gives this answer, and that it does not start a build.

## Setup

None. The workspace is empty.

## Prompt

`All our data is already in Snowflake. We want a set of SQL models that run every night inside Snowflake and build the tables behind our finance dashboards. Can we use DataSQRL for that?`

The prompt does not name a skill, so the case also checks that the `start` skill fires on a question about DataSQRL.

## Graders

| Grader | Type | Passes when |
|---|---|---|
| `start-fired` | `tool_used` | The `start` skill runs |
| `not-a-fit` | `llm` | The reply says that DataSQRL is not the right tool for scheduled models inside a warehouse, and points to dbt or SQLMesh |
| `no-build` | `tool_used` | The `requirements`, `plan`, `patch` and `implement` skills do not run |

## Run only this case

```bash
claude plugin eval . --eval-dir tests/claude-plugin-evals/skill-specific-tests --ablation none --runs 1 --case dbt-models-not-a-fit
```
