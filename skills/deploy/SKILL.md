---
name: deploy
description: Use when the user wants to deploy a DataSQRL project to DataSQRL Cloud, ship or release it, create a deployment, check how a deployment is going, or read its logs. Also use when they ask to sign in to DataSQRL Cloud or which organizations and projects they have.
argument-hint: '[optional git ref to deploy, defaults to HEAD]'
allowed-tools: Bash, Read, Skill
---

Deploy the current DataSQRL project to DataSQRL Cloud through its REST API.

Everything here goes through one script. Locate it exactly as the other skills locate the
launcher:

```bash
CLOUD="${CLAUDE_PLUGIN_ROOT}/scripts/datasqrl-cloud.sh"
[ -f "$CLOUD" ] || CLOUD=datasqrl-cloud.sh   # fall back to PATH
```

**Talk to the DataSQRL Cloud API only through the script.** It carries the token, keeps it fresh,
and offers exactly the operations that are allowed — which is what a hand-written `curl` call
would lose.

The script needs `curl` and `jq`. If `jq` is missing the script says so and prints the install line —
relay it and stop.

---

# Step 1 — Choose the commit

**The API deploys a commit GitHub already has.** It never uploads local files. So there is
exactly one hard requirement — the commit must be on a remote branch — and one thing the user
must not be surprised by: whatever is only in the working tree or in unpushed commits is not
in the deployment.

That makes this a question about _which_ commit, not a gate — and usually a question worth
asking. **The containerized agent leaves its work uncommitted on purpose**: it writes the
`.sqrl` scripts, package configs, GraphQL schema and tests into the working tree and the user
commits them. So a dirty tree holding an entire new pipeline is the *normal* state right after
an implementation run, and "deploy it" then almost certainly means the work just built, not the
older commit the remote happens to have. Deploying that older commit without asking ships
something other than what was requested.

Resolve the candidate first. `HEAD` unless the user named a ref (`/deploy v1.2.0`,
`/deploy origin/main`), in which case use `git rev-parse <ref>`.

```bash
git fetch --quiet                    # remote-tracking refs are stale otherwise
git rev-parse <candidate>            # the commit under consideration
git branch --show-current
git status --porcelain               # what is not in any commit
git branch -r --contains <sha>       # empty means the remote does not have it
```

`git fetch` first, always. `--contains` reads local remote-tracking refs, so without it a
commit pushed from another machine — or by a teammate — is reported as unpushed and the user
is asked to fix a problem they do not have. Fetching only updates refs; it touches no file in
the working tree.

## If the remote has the candidate

Clean tree → deploy it, and say nothing about git.

Dirty tree → find out whether the dirt is work the deployment would carry. Only the files the
DataSQRL compiler treats as project material matter; `adr/` and `.claude/` are the agent's own
bookkeeping and are dirty after every run, so counting them would raise a question on every
deploy:

```bash
git status --porcelain \
  | grep -vE '^.. (adr/|\.claude/|snapshots/|build/)' \
  | grep -E '\.(sqrl|graphqls?|csv|tsv|json|jsonl|ndjson|parquet|orc|avro)$|run-tests\.sh$'
```

**Nothing matches** — only bookkeeping, notes or snapshots are dirty. Say so in one line and
carry on with the deploy; nothing that runs would differ. A statement, not a question.

**Something matches** — the tree holds pipeline changes the deployment would leave out. Stop and
ask, because the two answers ship different code. Show the matching files and the candidate
commit's sha and subject, then offer:

1. **Commit and push the current work, then deploy that** — they run the git commands; you
   re-resolve `HEAD` and continue. This is what "deploy what I just built" means, and it is the
   likely intent straight after an implementation run.
2. **Deploy the pushed commit as it stands** — valid when the local changes are deliberately not
   for shipping yet. Name what would be excluded so the choice is informed.

Let them pick. Committing their work is theirs to authorize, and deploying code that predates
what they just asked you to build is not a default worth assuming.

## If the remote does not have the candidate

This is the only blocking case, and the fix is a choice the user makes:

```bash
git rev-parse --abbrev-ref --symbolic-full-name '@{u}'   # upstream, e.g. origin/main
git merge-base HEAD '@{u}'                               # newest pushed ancestor
git rev-list --count '@{u}..HEAD'                        # how many commits are unpushed
git log --oneline '@{u}..HEAD'                           # what they are
```

Present both options and let them pick:

1. **Deploy the newest pushed commit instead** — give its sha, subject, and what the unpushed
   commits above it contain, so they can see what they would be leaving out.
2. **Push first, then deploy `HEAD`** — they run `git push`; you re-check and continue.

**Never commit or push on their behalf**, and never pick between these for them: one deploys
older code than they may think, the other publishes work they may not have meant to publish.

`@{u}` fails when HEAD is detached or the branch has no upstream, and the `@{u}..HEAD` range
commands fail with it. In that case there is no "newest pushed ancestor" to offer — say which
situation it is and ask which ref to deploy rather than guessing. Deploying _from_ a detached
HEAD is fine once the commit is on a remote branch; only this fallback needs a branch.

The script only accepts a sha, on purpose: what gets deployed is the commit you resolved and
reported, not whatever a branch points at by the time the server looks.

# Step 2 — Sign in

Check for a usable token first; only sign in when there isn't one.

```bash
bash "$CLOUD" whoami || bash "$CLOUD" login
```

`login` prints a URL and an 8-character code and then waits. **A human has to open that URL in
a browser and approve it — you cannot.** Show the user the URL and the code verbatim and let
the command keep running; it polls for up to 10 minutes and prints the signed-in identity when
they approve.

Run `login` in the foreground so its output reaches the user as it appears. If your harness
cuts the command off before approval, say so and tell them to run it themselves in a terminal:

```bash
bash "$CLOUD" login
```

The token lasts an hour and refreshes itself silently afterwards, so this stop happens once per
session at most, not once per command.

# Step 3 — Organization

```bash
bash "$CLOUD" orgs
```

One organization → use it, and pass nothing. Several → ask the user which, then pass
`--org <id>` to every later command. There is no API that lists organizations; the ids come
from the signed-in token, and names are resolved through each org's project list, so an
organization with no projects shows only its id.

# Step 4 — Project

Let the script work it out before asking anything:

```bash
bash "$CLOUD" project-id                      # or --name 'Fraud Store' when the user named one
```

It prints one id when there is no ambiguity — a single project in the organization, or a project
whose `source` matches this repository's remote and whose `sourcePath` matches the directory you
are in. Take that id and continue without a question; state which project you resolved when you
report the deploy.

When it cannot pin one it exits with a message naming the real candidates. Relay that and ask —
its wording is more specific than a generic question, because it distinguishes "several projects
share this repository" from "this is not a git repository at all". Then pass `--project <id>`, or
`--name`, to every later command. For repeated deploys in one session the user can export
`DATASQRL_PROJECT_ID` instead.

Guessing from the directory name is the one thing to avoid — the match is on the repository
remote and path recorded in the project, not on what a folder happens to be called.

If the project does not exist in DataSQRL Cloud yet, stop: creating one is a Web UI task (Add
Project, which links a GitHub repository), and this skill cannot do it.

# Step 5 — Report the commit, then deploy

Deploy the commit settled in Step 1. Show its sha and subject line first, so what is going out
is on the screen next to the confirmation:

```bash
git log -1 --format='%H%n%s' <sha>
bash "$CLOUD" deploy --project <id> --commit <sha>
```

**Leave `--branch` off and let the script derive it.** It takes the deployment's branch label
from the commit itself — a remote branch that actually contains it, preferring the upstream, then
the repository's default branch. That is right in the cases where the checked-out branch is wrong:
deploying a tag or a sha from another branch would otherwise be labelled with whatever HEAD
happens to sit on, and in detached HEAD there is no branch to read at all. Pass `--branch`
only when the user explicitly asks for a specific label.

Add `--extra-package-json <paths...>` when the user names extra package.json overrides.

The command prints a `View it:` URL alongside the new deployment id — the Web UI page for that
deployment. **Pass that URL on to the user**; it is the thing they can act on, and a bare id is
not. When the script could not resolve it, it prints `Deployment id:` instead and you relay that.

**If it reports the commit is already deployed**, it names that deployment and creates nothing.
Report that to the user and ask whether they want a second deployment of the same commit. Only
if they say yes, re-run with `--force`. Never pass `--force` unprompted.

# Step 6 — Wait, then report

```bash
bash "$CLOUD" wait <deploymentId>
```

It polls once a minute for fifteen minutes and prints each status change.

The follow-ups are all subcommands of the same script — they are not standalone programs:

```bash
bash "$CLOUD" status <deploymentId>                              # current status, on demand
bash "$CLOUD" details <deploymentId>                             # per-stage timeline
bash "$CLOUD" logs --project <id> --deployment <deploymentId>    # logs
```

`status` and `details` need only the deployment id; `logs` is the one that also needs
`--project`. Add `--org <id>` to any of them if Step 3 found several organizations.

| Outcome                    | What to do                                                                                                                                                                                                                                                         |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `RUN` / `FINISH`           | Done. Give the user the **`View it:` URL** the command printed — that is the page for this deployment and what they actually want; an id alone is not actionable. Report the status, and that the project's main deployment is unchanged. End the turn — do not offer to promote it.                                                                                                                         |
| `FAILED`                   | Give the user the `View it:` URL, then run `bash "$CLOUD" details <deploymentId>` (per-stage timeline — a failed deploy is usually a compile failure) and `bash "$CLOUD" logs --project <id> --deployment <deploymentId>`, and report what they say. Diagnosing the running pipeline is beyond this skill: point the user at **Troubleshoot** in the Web UI, where the troubleshooting agent runs with the playbooks for it. |
| still pending after 15 min | **Not a failure.** A deployment can take longer. Hand back the `View it:` URL and `bash "$CLOUD" status <deploymentId>`, and end the turn.                                                                                                                            |

---

# What this skill cannot do

Stop and say where it happens. Do not look for another way round.

A new deployment does **not** become the project's main one, and this skill does not make it one.
If the user wants that, tell them the `promote` skill does it and stop — a separate request they
make after seeing the deploy result. Do not promote here even if they said "deploy and ship it",
and do not go read that skill to find out how.

| Request                                       | Where it happens                                   |
| --------------------------------------------- | -------------------------------------------------- |
| Make a deployment the project's main one      | the `promote` skill — tell the user, do not do it  |
| Terminate, stop, start or resize a deployment | Web UI — deployment page                           |
| Upgrade a deployment in place                 | Web UI (and only on installations that support it) |
| Create, edit or delete a project              | Web UI — Add Project / project settings            |
| Manage members, secrets or alert routing      | Web UI                                             |
| Diagnose a failing or unhealthy pipeline      | Web UI — **Troubleshoot**; that agent has the playbooks, this one does not |
| Deploy uncommitted or unpushed code           | Not possible — deploy a pushed commit, or push it  |
