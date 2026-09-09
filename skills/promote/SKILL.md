---
name: promote
description: Use when the user wants to make an existing DataSQRL Cloud deployment the project's main one - promote it to main, make it the primary or live deployment, or point production at it. Only for DataSQRL Cloud deployments, not for promoting a git branch, a release or a build artifact.
argument-hint: '[deployment id to promote]'
allowed-tools: Bash, Read, Skill
---

Make an existing DataSQRL Cloud deployment the project's **main** deployment.

**This changes what the project serves.** Promoting repoints the project's main deployment, so
traffic that reached the old one reaches the new one. Creating a deployment does not do this and
never implies it, so this runs only when the user asks for it in its own right — not as the tail
of anything else, and not inferred from "ship it".

Everything goes through one script:

```bash
CLOUD="${CLAUDE_PLUGIN_ROOT}/scripts/datasqrl-cloud.sh"
[ -f "$CLOUD" ] || CLOUD=datasqrl-cloud.sh   # fall back to PATH
```

**Never call the DataSQRL Cloud API with `curl` yourself.** The script holds the token, refreshes
it, and implements only the operations that are allowed.

It needs `curl` and `jq`. If `jq` is missing the script says so and prints the install line —
relay it and stop.

# Step 1 — Sign in

Check for a usable token first; only sign in when there isn't one.

```bash
bash "$CLOUD" whoami || bash "$CLOUD" login
```

`login` prints a URL and an 8-character code, then waits. **A human has to open that URL in a
browser and approve it — you cannot.** Show the URL and the code verbatim and let the command
keep running; it polls for up to 10 minutes. Run it in the foreground so its output reaches the
user as it appears. If your harness cuts it off before approval, say so and ask them to run
`bash "$CLOUD" login` themselves in a terminal.

The token lasts an hour and refreshes itself afterwards, so this happens once per session at most.

# Step 2 — Organization and project

```bash
bash "$CLOUD" orgs
```

One organization → use it and pass nothing. Several → ask which, then pass `--org <id>` to every
later command.

Ask the user which project, unless it is already settled in this conversation. If they give a name
rather than an id:

```bash
bash "$CLOUD" project-id --name 'Fraud Store'
```

Pass `--project <id>` to every later command.

# Step 3 — Show what changes

```bash
bash "$CLOUD" deployments --project <id>
```

The current main deployment is marked `MAIN` in that output. Do not skip this: the user is
choosing to replace something, and they cannot weigh that without seeing what it is.

If the deployment the user named is already the `MAIN` one, say so and stop — there is nothing to
do. If they gave a name or a commit rather than an id, resolve it from this list and confirm the
id back to them.

# Step 4 — Confirm, then promote

Ask for confirmation in a message that names **both** deployments — the one being promoted and the
one it replaces — with their statuses. Wait for the user to agree in their own words. An earlier
"deploy and promote it" does not count: that was said before they could see what main currently
is.

```bash
bash "$CLOUD" promote <deploymentId> --project <id>
```

The command prints a `View it:` URL for the promoted deployment — give that to the user rather
than the id, so they can confirm it is now main.

A promotion is not reversible by this skill — undoing it means promoting the previous deployment
back, which is another run of this same skill and needs the same confirmation.

# What this skill cannot do

| Request                                      | Where it happens                                    |
| -------------------------------------------- | --------------------------------------------------- |
| Create a deployment                          | the `deploy` skill                                  |
| Terminate, stop, start or resize             | Web UI — deployment page                            |
| Upgrade a deployment in place                | Web UI (and only on installations that support it)  |
| Change the project's own settings or members  | Web UI                                              |
