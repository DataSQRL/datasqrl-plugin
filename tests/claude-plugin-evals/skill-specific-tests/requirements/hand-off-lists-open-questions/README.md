# requirements-hand-off-lists-open-questions

Checks that the `requirements` skill writes the file with the new template sections, then hands it over with the open questions and waits.

## What it tests

- The [requirements template](../../../../../skills/requirements/reference/requirements-template.md) adds `## Results` and `## Hard constraints`.
- [Section 5](../../../../../skills/requirements/SKILL.md#5-hand-off) of the skill lists each open question on one line, with the selected default. It lists the questions about the architecture drivers first. It tells the user that they can answer in the file or in the chat. Then it waits.

## Setup

`fixture.sh` writes the same `notes.md` as the [asks-missing-drivers](../asks-missing-drivers/README.md) case. The notes give the source, the result and the freshness. They leave out the other drivers.

## Prompt

`/datasqrl:requirements Build the pipeline that notes.md describes. I have no more details right now, so write the requirements file now and record whatever is missing as open questions.`

The user says that they have no more facts, so the agent writes the file instead of asking first. The case needs `--allow-tools Write`.

## Graders

| Grader | Type | Passes when |
|---|---|---|
| `file-written` | `file_exists` | The run creates `adr/requirements_*.md` |
| `template-sections` | `tool_used` | The `Write` call contains `## Results`, `## Hard constraints` and `## Open Questions`, in that order |
| `hand-off` | `llm` | The reply gives the path, lists the open questions with a default for each, puts the driver questions before the detail questions, says where to answer, and asks "answer or plan with the defaults" |
| `no-plan` | `tool_used` | The `plan` skill does not run |

## Note

With no Bash, the agent cannot read the clock. The time in the file name is a placeholder, for example `requirements_20261112-120000.md`.

## Run only this case

```bash
claude plugin eval . --eval-dir tests/claude-plugin-evals/skill-specific-tests --scaffold --ablation none --allow-tools Write --runs 1 --case requirements-hand-off-lists-open-questions
```
