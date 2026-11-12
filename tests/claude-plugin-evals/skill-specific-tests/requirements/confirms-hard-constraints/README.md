# requirements-confirms-hard-constraints

Checks that the `requirements` skill keeps a "how" out of the file until the user confirms it, and keeps the API that the user defines.

## What it tests

- The "What, not how" driver in [Architecture drivers](../../../../../skills/requirements/SKILL.md#architecture-drivers): when the user mentions a how in passing, the agent asks whether it is hard. If it is not hard, the agent leaves it out. The prompt tells the agent to write the file now, so the agent records the question under `## Open Questions` instead of asking it in the chat.
- The [requirements template](../../../../../skills/requirements/reference/requirements-template.md) says: "The API surface that the user defines is a hard constraint".

## Setup

`fixture.sh` writes `notes.md` into a new git repository. The notes give:

- the Kafka topic `orders`, with a sample record
- "We could keep the totals in Postgres, I guess": a how, named in passing
- a GraphQL query `customerDailyTotals` that the mobile app already calls, with "keep it exactly as it is"

## Prompt

`/datasqrl:requirements Build the pipeline that notes.md describes. I have no more details right now, so write the requirements file now and record whatever is missing as open questions.`

The case needs `--allow-tools Write`.

## Graders

| Grader | Type | Passes when |
|---|---|---|
| `file-written` | `file_exists` | The run creates `adr/requirements_*.md` |
| `keeps-the-query` | `tool_used` | The `Write` call has `customerDailyTotals` under `## Hard constraints` or `## API surface` |
| `postgres-not-hard` | `tool_used` | The `Write` call has no sentence under `## Hard constraints` that makes Postgres required, such as "must use Postgres". A note such as "Postgres is not a hard constraint" passes |
| `postgres-is-open-question` | `tool_used` | The `Write` call names Postgres under `## Open Questions` |
| `no-plan` | `tool_used` | The `plan` skill does not run |

## Run only this case

```bash
claude plugin eval . --eval-dir tests/claude-plugin-evals/skill-specific-tests --scaffold --ablation none --allow-tools Write --runs 1 --case requirements-confirms-hard-constraints
```
