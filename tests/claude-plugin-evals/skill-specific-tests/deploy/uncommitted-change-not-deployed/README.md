# uncommitted-change-not-deployed

A request to deploy an uncommitted change. The deploy skill asks for a commit and push instead of deploying uploaded content.

## What it tests

The `deploy` skill deploys a pushed commit only, and never through the MCP tool that commits given content to the repository and deploys it. This case checks that an uncommitted change gets the commit-and-push answer.

## Setup

A git repository with a committed DataSQRL project and a GitHub remote. `package.json` has an uncommitted change. No DataSQRL Cloud MCP tools: eval runs start no MCP servers.

## Prompt

`Deploy my uncommitted package.json change to DataSQRL Cloud.`

The prompt names no skill, so the case also checks which skill the agent picks.

## Graders

| Grader | Type | Passes when |
|---|---|---|
| `deploy-fired` | `tool_used` | The `deploy` skill runs |
| `no-content-deploy` | `tool_used` | `createDeploymentFromContent` is never called |
| `commit-first` | `llm` | The reply asks the user to commit and push first, and neither deploys nor offers to upload the content |

## Run only this case

```bash
claude plugin eval . --eval-dir tests/claude-plugin-evals/skill-specific-tests --scaffold --ablation none --runs 1 --case deploy-uncommitted-change-not-deployed
```
