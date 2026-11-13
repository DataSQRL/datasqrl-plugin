# alerts-route-to-cloud

A request for alerts. The cloud skill takes it, not the deploy skill.

## What it tests

The `cloud` skill's description claims alerts. This case checks that an alerts request reaches it and not `deploy`, which owns deployment status and logs.

## Setup

A git repository with a committed DataSQRL project and a GitHub remote. No DataSQRL Cloud MCP tools: eval runs start no MCP servers.

## Prompt

`Show me the alerts on my DataSQRL Cloud deployments.`

The prompt names no skill, so the case also checks which skill the agent picks.

## Graders

| Grader | Type | Passes when |
|---|---|---|
| `cloud-fired` | `tool_used` | The `cloud` skill runs |
| `deploy-not-fired` | `tool_used` | The `deploy` skill does not run |

## Run only this case

```bash
claude plugin eval . --eval-dir tests/claude-plugin-evals/skill-specific-tests --scaffold --ablation none --runs 1 --case cloud-alerts-route-to-cloud
```
