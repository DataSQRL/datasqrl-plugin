# requirements-pushes-back-on-realtime

Checks that the `requirements` skill questions a "realtime" request before it accepts it.

## What it tests

The freshness driver in [Architecture drivers](../../../../../skills/requirements/SKILL.md#architecture-drivers) says: "Push back on "realtime", because it costs more to build and run. Ask what would break if results were minutes or hours old." This case checks that the agent does this.

## Setup

`fixture.sh` writes `notes.md` into a new git repository. The notes ask for a "realtime dashboard API" with the hourly average temperature of each machine. They give no reason why older results would not do. They give the Kafka topic `sensor-readings`, a sample record and the rate: 200 sensors, one reading every 10 seconds.

## Prompt

`/datasqrl:requirements Build the pipeline that notes.md describes.`

The case has no `Write` tool, so the run ends at the agent's first questions.

## Graders

| Grader | Type | Passes when |
|---|---|---|
| `asks-acceptable-staleness` | `llm` | The reply asks how old the results can be, or what breaks if they are some minutes old |
| `no-plan` | `tool_used` | The `plan` skill does not run |

## Run only this case

```bash
claude plugin eval . --eval-dir tests/claude-plugin-evals/skill-specific-tests --scaffold --ablation none --runs 1 --case requirements-pushes-back-on-realtime
```
