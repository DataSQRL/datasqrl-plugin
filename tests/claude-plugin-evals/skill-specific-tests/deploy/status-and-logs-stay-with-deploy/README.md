# status-and-logs-stay-with-deploy

A deployment status and logs request. The deploy skill takes it, not the cloud skill.

## What it tests

Deployment status and logs belong to the `deploy` skill. The `cloud` skill covers the rest of DataSQRL Cloud and routes status and logs to `deploy`. This case checks that the two do not overlap.

## Setup

A git repository with a committed DataSQRL project and a GitHub remote. No DataSQRL Cloud MCP tools: eval runs start no MCP servers.

## Prompt

`How is my latest DataSQRL Cloud deployment of this project doing? Show me its logs.`

The prompt names no skill, so the case also checks which skill the agent picks.

## Graders

| Grader | Type | Passes when |
|---|---|---|
| `deploy-fired` | `tool_used` | The `deploy` skill runs |
| `cloud-not-fired` | `tool_used` | The `cloud` skill does not run |

## Run only this case

```bash
claude plugin eval . --eval-dir tests/claude-plugin-evals/skill-specific-tests --scaffold --ablation none --runs 1 --case deploy-status-and-logs-stay-with-deploy
```
