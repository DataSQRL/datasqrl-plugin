# requirements-records-user-hard-constraint

Checks that the `requirements` skill writes a "how" under `## Hard constraints` when the user says that it is required, and keeps the user's reason with it.

This case is the positive pair of [confirms-hard-constraints](../confirms-hard-constraints/README.md). In that case, the user names Postgres only in passing, so Postgres must not be a hard constraint.

## What it tests

- The "What, not how" driver in [Architecture drivers](../../../../../skills/requirements/SKILL.md#architecture-drivers): name a how only when it is a hard constraint, and mark it as one.
- The `## Hard constraints` section of the [requirements template](../../../../../skills/requirements/reference/requirements-template.md): "The hows that are not negotiable, each with its reason".

## Setup

`fixture.sh` writes `notes.md` into a new git repository. The notes give:

- the Kafka topic `orders`, with a sample record that has an order `description`
- the result: each order classified into one category, and a GraphQL API with the number of orders in each category for each day
- the hard constraint: "The classification must use the OpenAI model `gpt-5-mini`. Our legal team approved only this model for customer data, so we cannot use any other model."

## Prompt

`/datasqrl:requirements Build the pipeline that notes.md describes. I have no more details right now, so write the requirements file now and record whatever is missing as open questions.`

The case needs `--allow-tools Write`.

## Graders

| Grader | Type | Passes when |
|---|---|---|
| `file-written` | `file_exists` | The run creates `adr/requirements_*.md` |
| `model-under-hard-constraints` | `tool_used` | The `Write` call names `gpt-5-mini` under `## Hard constraints` |
| `reason-under-hard-constraints` | `tool_used` | The `Write` call gives the reason under `## Hard constraints`: it names the legal team or the approval |
| `no-plan` | `tool_used` | The `plan` skill does not run |

## Run only this case

```bash
claude plugin eval . --eval-dir tests/claude-plugin-evals/skill-specific-tests --scaffold --ablation none --allow-tools Write --runs 1 --case requirements-records-user-hard-constraint
```
