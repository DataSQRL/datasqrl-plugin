---
name: resolve-issue
description: Use when the user wants a GitHub issue on a DataSQRL project resolved, fixed or implemented - they give an issue URL or number, or refer to an issue the DataSQRL Cloud assistant filed. Reads the issue, runs the DataSQRL Code Agent over it from the project's directory in the lane the fix needs, and hands them the commit message that closes the issue.
argument-hint: "<issue URL | issue number>"
allowed-tools: Bash, Read, Write, Skill
---
# Resolve a GitHub issue

Turns a GitHub issue into a DataSQRL Code Agent run on the project it is about.

Issues filed by the DataSQRL Cloud assistant report a defect in the user's project: actual and expected behaviour, evidence, where it surfaces and acceptance criteria. They stop at the evidence, because deciding the fix is the agent's work. Below the report, after a `---` line, the platform appends a footer naming the requester, the project and its directory in the repository.

## Step 1 — make sure the agent image is here

Run this first, so a missing image surfaces before any of the work below. It is a no-op when the image is already present:

```bash
if ! docker image inspect datasqrl-code-agent:latest >/dev/null 2>&1; then
  echo "Fetching the DataSQRL agent image..."
  docker pull ghcr.io/datasqrl/code-agent:latest &&
    docker tag ghcr.io/datasqrl/code-agent:latest datasqrl-code-agent:latest
fi
```

Run it without prompting, and continue silently on success. On a failure, relay Docker's own message and follow the table in step 1a of the [`start` skill](../start/SKILL.md), which covers a private package and a stopped daemon.

## Step 2 — read the issue

```bash
gh issue view "$ARGUMENTS" --json number,title,body,state,url
```

- `$ARGUMENTS` is the issue URL, or its number when the current directory is a clone of the issue's repository.
- Without a signed-in `gh`, a public issue reads over the REST API:
  ```bash
  curl -fsSL "https://api.github.com/repos/<owner>/<repo>/issues/<number>" |
    jq '{number, title, body, state, url: .html_url}'
  ```
  For a private repository, ask the user to run `gh auth login` and stop.
- A closed issue: say so and ask whether to resolve it anyway.

Split the body at its **last** line that is exactly `---`: above it is the report, below it the footer. An issue with no such line is all report.

## Step 3 — locate the project

1. **The repository.** `git remote -v` must name the issue's `<owner>/<repo>`. For any other repository, ask the user where their clone of that one is, and stop.
2. **The project directory.** The footer's `**Project directory**` line gives the project's path from the repository root, `.` for the root itself. Run every later step from there:
   ```bash
   cd "$(git rev-parse --show-toplevel)/<project directory>"
   ```
   For an issue whose footer predates that line, ask the user which directory holds the project, with the current one as the default.

## Step 4 — write the issue as requirements

Write `adr/requirements_<YYYYMMDD-HHMMSS>.md` in the project directory, using the current date and time. Create `adr/` when it is absent.

```markdown
# <issue title>

Resolves <issue URL>

<the report, verbatim>
```

Copy the report verbatim: it is the whole requirement the agent reads. The footer stays behind in the issue, since it addresses people and this skill.

## Step 5 — route

The report states what is wrong and leaves the change open, so route on the size of the fix it implies.

- **Patch** — the defect sits in a handful of existing files: a compile or configuration error, a wrong value, one table, view or query. Use the [`patch` skill](../patch/SKILL.md) with the requirements file's path as its request; the report's acceptance criteria are what determine the change.
- **Full workflow** — the fix needs new logic, a new source or a redesign, or the report spans several tables. Run the [`plan` skill](../plan/SKILL.md) over that file, summarize the plan it writes — the fix it proposes, its assumptions, its checklist — for the user to review and edit, and run [`implement`](../implement/SKILL.md) once they approve it.

When the lane is unclear, ask in one line and state your default. A patch run that reports the change is larger than a patch continues in the full workflow over the same file.

## Step 6 — when the run finishes

Report the result as the lane's skill describes, and in both lanes say what the run changed: the files it touched and what it did to each, read from `git status` and `git diff` in the project directory. The run leaves those changes uncommitted, so ask the user to review them, and give them the commit message that closes the issue:

```
<one-line summary of the change>

Fixes <owner>/<repo>#<number>
```

GitHub closes the issue when a commit or merged pull request carrying that line reaches the default branch. Committing, pushing and closing stay with the user.

A failed run leaves the issue open: report the failure and stop.
