---
name: cloud
description: Use when the user wants to look at or change something in DataSQRL Cloud other than deploying a commit or promoting a deployment - alerts, metrics, logs, deployment status, projects, secrets, members, or terminating, stopping, starting or resizing a deployment. Not for creating a deployment from a commit (the deploy skill) or making one the project's main deployment (the promote skill).
allowed-tools: Bash, Read, Skill
---

Work with DataSQRL Cloud through the tools of the `datasqrl` MCP server that this plugin connects.

There is one tool per DataSQRL Cloud API operation, named after it (for example a tool that lists
deployments or runs a deployment action). Pick the tool by its description, and read its input
schema for the ids it needs.

The plugin's script handles sign-in and a few lookups:

```bash
CLOUD="${CLAUDE_PLUGIN_ROOT}/scripts/datasqrl-cloud.sh"
[ -f "$CLOUD" ] || CLOUD=datasqrl-cloud.sh   # fall back to PATH
```

**Never call the DataSQRL Cloud API with `curl` yourself.** Use the tools; the plugin gives them
the token and keeps it fresh.

# Route first

| Request                                         | Use                                      |
| ----------------------------------------------- | ---------------------------------------- |
| Deploy a commit, create a deployment            | the `deploy` skill, not a tool           |
| Make a deployment the project's main one        | the `promote` skill, not a tool          |
| Diagnose why a running pipeline misbehaves      | Web UI — **Troubleshoot**; that agent has the playbooks. Logs and status from the tools are fine to show first. |
| Everything else in DataSQRL Cloud               | the tools, as below                      |

The deploy and promote skills check the commit and the current main deployment before they act,
which a bare tool call skips.

# Step 1 — Find the ids

Most tools need an organization id, and many a project or deployment id.

- Organizations the user belongs to: `bash "$CLOUD" orgs`.
- The project for this repository: `bash "$CLOUD" project-id`. With a name: `--name NAME`.
- Otherwise list projects or deployments with the tools and match what the user said.

If more than one candidate fits, ask. Never guess an id for a change.

# Step 2 — Call the tools

Read-only tools (listing, status, logs, metrics, alerts) can run straight away. Report what they
return in plain words, with the ids the user may need next.

**A destructive tool needs the user's go-ahead in this conversation.** Do not count on the client
to ask: depending on its permission settings, it may run the tool without a prompt.

- The user's own words name the action and a target that matches exactly one deployment or project
  ("terminate deployment 21fc9306", "delete project orders-dev"): say what the call will do, then
  run it.
- Anything else, such as a target you matched from a list or a broad request like "clean up the old
  deployments": say what the call will do and wait for a yes in the user's own words.

Saying what the call will do means naming the action, the deployment or project by name and id,
and what the user loses (a terminated deployment stops serving and does not come back). If the
user or the client declines, stop; do not look for another way to do it.

# When the tools fail or are missing

- **"not authenticated" or "could not refresh the access token":** sign in, then retry the call.

  ```bash
  bash "$CLOUD" whoami || bash "$CLOUD" login
  ```

  `login` prints a URL and a code and waits. **A human has to approve it in a browser — you
  cannot.** Show the URL and the code verbatim and let the command keep running.

- **No DataSQRL tools at all:** the MCP server is not connected. In Claude Code, the user runs
  `/mcp` and reconnects `datasqrl`. In Codex or Cursor, they restart the session after signing in.
  Say so and stop.

- **HTTP 403:** the signed-in user has no access to that organization or project. Say which one.

- **HTTP 429:** too many requests. Wait the number of seconds the error gives, then retry once.
