#!/bin/bash
#
# TWO BYTE-IDENTICAL COPIES OF THIS FILE EXIST. Edit only the first:
#
#   agent/codeagent.sh                     <- canonical; edit this one
#   datasqrl-plugin/scripts/codeagent.sh   <- copy shipped inside the plugin
#
# then run:  ./agent/sync-launcher.sh
#
# CI fails if they differ, so the copy cannot drift silently. A symlink would be
# the obvious way to avoid the duplication, and it does not work: Claude Code,
# Codex and Cursor all COPY a plugin into a local cache on install, and a
# relative symlink whose target lives outside the plugin directory is dropped by
# that copy — the installed plugin ends up with an empty scripts/ and every skill
# fails to find this launcher.
#
# Run DataSQRL Code Agent with local or cloud MCP server.
# Run this script from the workspace directory containing your DataSQRL project.
#
# Usage: ./codeagent.sh <requirements> [options...]
#
# The requirements string is the first positional argument. Any additional
# arguments are forwarded directly to the Python CLI (e.g., --mode,
# --disable-verification, --dry-run).
#
# Lifetime flags owned by THIS script (never forwarded to the Python CLI):
#
#   --detach   Start the run in a detached container and return in ~2s, printing the run
#              name. The run is owned by the Docker daemon, not by this shell, so it
#              survives the caller exiting, being interrupted, or timing out. Intended for
#              programmatic callers (Claude Code and other coding agents, CI). Interactive
#              users normally omit it and keep the streaming output.
#   --status   Print one status line: the in-flight run (last step, last activity), or the last
#              run's result. `--status N` prints the last N lines of the progress trail first.
#   --stop     Stop this project's in-flight run.
#   --wait     Block until this project's in-flight run ends, then print the --status line and
#              exit with the container's exit code. For programmatic callers: run it in the
#              background right after --detach and let your harness notify you when it exits.
#   --pull-image    Pull the selected edition's image, or update it when a newer build exists.
#                   Starts no run.
#   --image-exists  Print whether the selected edition's image is local; exit 0 or 1. Never pulls.
#
# The image flags work in any directory and take no other argument. The edition is os unless
# DATASQRL_AGENT_EDITION=pro, DATASQRL_PRO_TOKEN is set, or pro-agent:latest is already exist.
# DATASQRL_PRO_TOKEN is a GitHub token with read:packages; it unlocks the private pro image.
#
# REQUIRES A GIT REPOSITORY. Run it from the SQRL project directory you want to build; the
# repository around that project defines what the agent can see:
#
#     -v <repo-root>:/workspace:ro                  whole repo, READ-ONLY (so the agent can
#                                                   discover sibling projects / shared catalogs)
#     -v <repo-root>/<project>:/workspace/<project> your project, READ-WRITE (the ONLY writable
#                                                   place — nothing else can be modified)
#
# Because the repo's directory structure is preserved verbatim, every relative path the agent
# writes (e.g. "script.include": {"data_catalog": {"package": "../data-catalog/package.json"}}) is equally valid in your real repo.
# Invoked at the repo root, the project IS the repo and a single read-write mount is used.
#
# Set CODEAGENT_ALLOW_NO_GIT=1 to bypass the git requirement (CI/automation only); the current
# directory is then treated as a standalone single project.
#
# Authentication (in order of precedence):
#   1. ANTHROPIC_API_KEY env var
#   2. CLAUDE_CODE_OAUTH_TOKEN env var (from `claude setup-token`)
#   3. ~/.claude/.credentials.json (from `claude login`)
#   4. macOS Keychain (extracted automatically from `claude login`)
#
# AWS_PROFILE (optional): used only by a Bedrock run (--provider amazon-bedrock) or an opted-in log
# upload (DATASQRL_TELEMETRY=1); every other run ignores it. The profile becomes one temporary credential
# here on the host, and only that credential reaches the container; ~/.aws is never mounted.
# Access keys already set win over the profile. For an SSO profile, log in first with
# `aws --profile <name> sso login`. Needs the AWS CLI v2.
#
# Telemetry (optional, opt-in, off by default): DATASQRL_TELEMETRY=1 with AWS_ACCESS_KEY_ID and
# AWS_SECRET_ACCESS_KEY uploads the run log to DataSQRL for troubleshooting and debugging. Without
# DATASQRL_TELEMETRY=1 the log stays in the project, whatever AWS credentials are set.

# The images. Each edition is published under its own name and runs under a short local tag, the
# same tag `build-docker-local.sh` gives a local build, so a local build is picked up with no extra
# flag. Preflight pulls the published image and tags it when the local tag is missing.
OS_REGISTRY_IMAGE="ghcr.io/datasqrl/adv-agent:latest"
OS_LOCAL_IMAGE="adv-agent:latest"
PRO_REGISTRY_IMAGE="ghcr.io/datasqrl/pro-agent:latest"
PRO_LOCAL_IMAGE="pro-agent:latest"
# A name for people typing `docker run` by hand: the pro image when there is one, else os.
# Runs never use it, since it moves with whichever edition was pulled.
COMMON_IMAGE="datasqrl-agent:latest"

# --- Image helpers -----------------------------------------------------------------------------
# Sets RUN_EDITION, REGISTRY_IMAGE and LOCAL_IMAGE. The first rule that matches wins:
#   1. DATASQRL_AGENT_EDITION, when set
#   2. pro, when DATASQRL_PRO_TOKEN is set
#   3. pro, when the pro image is already local (a user who has both runs pro)
#   4. os
resolve_edition() {
    case "${DATASQRL_AGENT_EDITION:-}" in
        os|pro) RUN_EDITION="$DATASQRL_AGENT_EDITION" ;;
        "")
            if [ -n "${DATASQRL_PRO_TOKEN:-}" ] \
               || docker image inspect "$PRO_LOCAL_IMAGE" >/dev/null 2>&1; then
                RUN_EDITION="pro"
            else
                RUN_EDITION="os"
            fi
            ;;
        *)
            echo "Error: DATASQRL_AGENT_EDITION must be 'os' or 'pro', not '$DATASQRL_AGENT_EDITION'." >&2
            exit 1
            ;;
    esac
    if [ "$RUN_EDITION" = "pro" ]; then
        REGISTRY_IMAGE="$PRO_REGISTRY_IMAGE"
        LOCAL_IMAGE="$PRO_LOCAL_IMAGE"
    else
        REGISTRY_IMAGE="$OS_REGISTRY_IMAGE"
        LOCAL_IMAGE="$OS_LOCAL_IMAGE"
    fi
}

image_label() {
    docker image inspect -f "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null
}

# "edition: pro · version: 1.0.712". CI stamps the version; a local build has none.
image_summary() {
    _ed="$(image_label "$1" com.datasqrl.edition)"
    _ver="$(image_label "$1" org.opencontainers.image.version)"
    printf 'edition: %s · version: %s' "${_ed:-unknown}" "${_ver:-local build}"
}

# Logs Docker in to ghcr.io with DATASQRL_PRO_TOKEN, a GitHub personal access token (classic) with
# the read:packages scope. The token only ever travels on stdin, never as an argument, so `ps`
# cannot show it, and it is not forwarded into the container. GHCR identifies the account from
# the token alone, but the login uses the token owner's real username, as GitHub documents it.
# Docker keeps the login, so later pulls need no token.
pro_login() {
    if ! command -v curl >/dev/null 2>&1; then
        echo "Error: DATASQRL_PRO_TOKEN needs curl on this machine to look up the token's account." >&2
        exit 1
    fi
    _resp="$(printf 'Authorization: Bearer %s\n' "$DATASQRL_PRO_TOKEN" \
        | curl -s -H @- -w '\n%{http_code}' https://api.github.com/user 2>/dev/null)"
    _code="${_resp##*$'\n'}"
    _user="$(printf '%s\n' "${_resp%$'\n'*}" \
        | grep -o '"login": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
    if [ "$_code" = "401" ] || [ "$_code" = "403" ]; then
        echo "Error: GitHub rejected DATASQRL_PRO_TOKEN: the token is invalid or expired." >&2
        echo "Ask DataSQRL for a new token, or unset DATASQRL_PRO_TOKEN to run the open-source edition." >&2
        exit 1
    fi
    if [ "$_code" != "200" ] || [ -z "$_user" ]; then
        echo "Error: could not reach GitHub to check DATASQRL_PRO_TOKEN (HTTP ${_code:-none})." >&2
        exit 1
    fi
    if ! printf '%s' "$DATASQRL_PRO_TOKEN" \
         | docker login ghcr.io -u "$_user" --password-stdin >/dev/null 2>&1; then
        echo "Error: ghcr.io refused the login for '$_user'." >&2
        echo "The token needs the 'read:packages' scope, and its GitHub account needs access to the" >&2
        echo "pro edition from DataSQRL." >&2
        exit 1
    fi
    echo "Logged in to ghcr.io as $_user." >&2
}

# Pulls REGISTRY_IMAGE and tags it as LOCAL_IMAGE. A failed pull stops the launcher. It never
# switches to the other edition, because that would give a pro user the os image.
ensure_image() {
    if [ "$RUN_EDITION" = "pro" ] && [ -n "${DATASQRL_PRO_TOKEN:-}" ]; then
        pro_login
    fi
    echo "Pulling $REGISTRY_IMAGE ($RUN_EDITION edition, ~3GB the first time)..." >&2
    if ! docker pull "$REGISTRY_IMAGE"; then
        echo "" >&2
        echo "Error: could not pull '$REGISTRY_IMAGE'." >&2
        if [ "$RUN_EDITION" = "pro" ] && [ -n "${DATASQRL_PRO_TOKEN:-}" ]; then
            echo "" >&2
            echo "The login worked, so the token's GitHub account most likely has not been given access" >&2
            echo "to the pro edition by DataSQRL. Ask DataSQRL to grant it, or set DATASQRL_AGENT_EDITION=os" >&2
            echo "to run the open-source edition." >&2
        elif [ "$RUN_EDITION" = "pro" ]; then
            echo "" >&2
            echo "The pro image is private. Set DATASQRL_PRO_TOKEN to the token DataSQRL gave you." >&2
            echo "" >&2
            echo "If DataSQRL has given your own GitHub account access to the pro edition, you can use" >&2
            echo "a personal access token (classic) from that account with the 'read:packages' scope" >&2
            echo "instead: set it as DATASQRL_PRO_TOKEN, or log in once yourself:" >&2
            echo "" >&2
            echo "  echo \"\$GITHUB_PAT\" | docker login ghcr.io -u <your-github-username> --password-stdin" >&2
            echo "" >&2
            echo "Then re-run this command. To run the open-source edition instead, set DATASQRL_AGENT_EDITION=os." >&2
        fi
        exit 1
    fi
    if ! docker tag "$REGISTRY_IMAGE" "$LOCAL_IMAGE"; then
        echo "Error: pulled '$REGISTRY_IMAGE' but could not tag it as '$LOCAL_IMAGE'." >&2
        exit 1
    fi
    # The common tag follows pro whenever pro is local, so pulling os never takes it from pro.
    if [ "$RUN_EDITION" = "pro" ] || ! docker image inspect "$PRO_LOCAL_IMAGE" >/dev/null 2>&1; then
        docker tag "$LOCAL_IMAGE" "$COMMON_IMAGE" >/dev/null 2>&1
    fi
    echo "Pulled $REGISTRY_IMAGE as $LOCAL_IMAGE · $(image_summary "$LOCAL_IMAGE")" >&2
}

require_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "Error: docker is not installed or not on PATH." >&2
        exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
        echo "Error: cannot talk to the Docker daemon. Is Docker running?" >&2
        exit 1
    fi
}

# --pull-image: always pulls the selected edition, even when it is local, so it also updates.
do_pull_image() {
    if [ -n "${DATASQRL_AGENT_IMAGE:-}" ]; then
        echo "Error: DATASQRL_AGENT_IMAGE is set to '$DATASQRL_AGENT_IMAGE', and a custom image is never pulled." >&2
        echo "Unset it to pull the published image." >&2
        return 1
    fi
    resolve_edition
    ensure_image
}

# --image-exists: one line on stdout, exit 0 when the selected image is local and 1 when it is not.
# It never pulls, so a caller can decide what to do next.
do_image_exists() {
    if [ -n "${DATASQRL_AGENT_IMAGE:-}" ]; then
        _img="$DATASQRL_AGENT_IMAGE"; _what="$DATASQRL_AGENT_IMAGE"
    else
        resolve_edition
        _img="$LOCAL_IMAGE"; _what="$LOCAL_IMAGE ($RUN_EDITION edition)"
    fi
    if docker image inspect "$_img" >/dev/null 2>&1; then
        printf '%s is present · %s\n' "$_img" "$(image_summary "$_img")"
        return 0
    fi
    printf '%s is missing · run: codeagent.sh --pull-image\n' "$_what"
    return 1
}

# --- Argument partitioning ---------------------------------------------------------------------
# Lifetime flags are consumed here and MUST NOT reach the Python CLI, which does not know them.
# Everything else is left in place for the requirements/forwarding split below.
DETACH=0
ACTION="run"
TAIL_N=0          # --status N: print the last N trail lines before the status line
REST_ARGS=()
_after_status=0
for _arg in "$@"; do
    if [ "$_after_status" = "1" ]; then
        _after_status=0
        case "$_arg" in
            *[!0-9]*|'') ;;                    # not a number: plain --status
            *) TAIL_N="$_arg"; continue ;;
        esac
    fi
    case "$_arg" in
        --detach) DETACH=1 ;;
        --status) ACTION="status"; _after_status=1 ;;
        --stop)   ACTION="stop" ;;
        --wait)   ACTION="wait" ;;
        --pull-image)   ACTION="pull-image" ;;
        --image-exists) ACTION="image-exists" ;;
        *)        REST_ARGS+=("$_arg") ;;
    esac
done
set -- "${REST_ARGS[@]}"

# The image actions run before the repository check: they touch no project, so they work from
# any directory, including before a project exists.
case "$ACTION" in
    pull-image|image-exists)
        if [ $# -gt 0 ] || [ "$DETACH" = "1" ]; then
            echo "Error: --$ACTION takes no other arguments." >&2
            exit 1
        fi
        require_docker
        if [ "$ACTION" = "pull-image" ]; then do_pull_image; else do_image_exists; fi
        exit $?
        ;;
esac

# The requirements are the first positional argument — but only if it actually IS one. A leading
# token that starts with '-' is a flag (e.g. `codeagent.sh --mode implementation`, which
# auto-discovers the latest plan and legitimately has no requirements argument). Treating a flag
# as the requirements string silently corrupts the whole argument list, so guard against it.
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
    REQUIREMENTS="$1"
    shift
else
    REQUIREMENTS=""
fi

# Arguments forwarded verbatim to the Python CLI
FORWARD_ARGS=("$@")

# Host project directory (the directory this script is invoked from)
HOST_WS="$PWD"

# --- Locate the repository (hard requirement) --------------------------------------------------
# The repo defines what the agent can see. MOUNT_DIR is mounted read-only so sibling projects and
# shared catalogs are discoverable; PROJECT_REL locates this project inside it. `--show-prefix`
# gives the FULL relative path (not just a basename), which is what preserves the real directory
# depth so relative paths written in the container stay valid in the user's repo.
if MOUNT_DIR="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    PROJECT_REL="$(git rev-parse --show-prefix 2>/dev/null)"
    PROJECT_REL="${PROJECT_REL%/}"        # --show-prefix has a trailing slash
    PROJECT_REL="${PROJECT_REL:-.}"       # empty at the repo root
elif [ "${CODEAGENT_ALLOW_NO_GIT:-}" = "1" ]; then
    # Escape hatch for CI/automation: treat the current directory as a standalone project.
    MOUNT_DIR="$(pwd -P)"
    PROJECT_REL="."
    echo "Warning: not inside a git repository; CODEAGENT_ALLOW_NO_GIT=1 set, continuing with the current directory only." >&2
else
    echo "Error: the code agent must be run inside a git repository." >&2
    echo "" >&2
    echo "The repository is what lets the agent discover sibling SQRL projects and shared data" >&2
    echo "catalogs, and it is mounted read-only so nothing outside your project can be modified." >&2
    echo "" >&2
    echo "Fix by either:" >&2
    echo "  - cd into an existing repository that contains your project, or" >&2
    echo "  - run 'git init' at the root of your project group (the directory that holds your" >&2
    echo "    project and any shared data catalog)." >&2
    echo "" >&2
    echo "For CI/automation only, set CODEAGENT_ALLOW_NO_GIT=1 to bypass this check." >&2
    exit 1
fi

# --- Run identity ------------------------------------------------------------------------------
# One run at a time per project. The container NAME is the lock: Docker rejects a second container
# with the same name, atomically, in the daemon — so two agents can never edit one project
# concurrently (they would interleave writes to the same .sqrl files, the same build/, and the same
# plan checklist). The name must therefore be DETERMINISTIC per project — no timestamp in it, or
# every run would get a fresh name and lock nothing.
#
# --rm is what keeps the lock from going stale: an exited container would otherwise keep holding
# its name forever, and every later run would be refused until someone ran `docker rm` by hand.
# With --rm the lock is released by the same event that ends the run, however it ends.
#
# The path hash disambiguates same-named projects in different locations (two `analytics/` dirs).
if [ "$PROJECT_REL" = "." ]; then
    PROJECT_ABS="$MOUNT_DIR"
else
    PROJECT_ABS="$MOUNT_DIR/$PROJECT_REL"
fi

_short_hash() {
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum | cut -c1-8
    elif command -v sha1sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha1sum | cut -c1-8
    else
        printf '%s' "$1" | cksum | tr -d ' ' | cut -c1-8
    fi
}

PROJECT_SLUG="$(printf '%s' "$(basename "$PROJECT_ABS")" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9_.-]/-/g' \
    | cut -c1-40)"
[ -z "$PROJECT_SLUG" ] && PROJECT_SLUG="project"
RUN_NAME="codeagent-${PROJECT_SLUG}-$(_short_hash "$PROJECT_ABS")"

# The container writes both of these into the project through the bind mount, so they are live on
# the host while the run is going. They — not `docker logs` — are the status channel, which is what
# makes --rm safe and lets --status re-attach from a different shell or a later session.
#
# PROGRESS_PATH is the human-readable trail the container renders from its log: one record per
# line, `+HH:MM:SS  KIND   text`, continuation lines indented. Truncated when a run starts and left
# in place afterwards, so the last run's trail can be revisited until the next run overwrites it.
PROGRESS_PATH="$PROJECT_ABS/.claude/codeagent-progress.txt"
RESULTS_PATH="$PROJECT_ABS/.code_agent_results.json"

# --- Shared helpers ----------------------------------------------------------------------------
run_is_live() {
    [ -n "$(docker ps -q -f "name=^${RUN_NAME}$" 2>/dev/null)" ]
}

# Empty for a container that predates this label (or any non-numeric value), so callers print no
# elapsed time rather than an absurd one measured from the epoch.
run_started_epoch() {
    _e="$(docker inspect -f '{{index .Config.Labels "codeagent.started"}}' "$RUN_NAME" 2>/dev/null)"
    case "$_e" in
        ''|*[!0-9]*|0) return 0 ;;
        *) printf '%s' "$_e" ;;
    esac
}

run_mode_label() {
    docker inspect -f '{{index .Config.Labels "codeagent.mode"}}' "$RUN_NAME" 2>/dev/null
}

fmt_elapsed() {
    _s="${1:-0}"
    if [ "$_s" -lt 60 ]; then
        printf '%ds' "$_s"
    elif [ "$_s" -lt 3600 ]; then
        printf '%dm' $((_s / 60))
    else
        printf '%dh%dm' $((_s / 3600)) $(((_s % 3600) / 60))
    fi
}

# Modification time as epoch seconds, portable across GNU (Linux) and BSD (macOS). GNU first: GNU
# `stat -f` takes no argument, so the BSD form would make GNU print file-system status to stdout
# before failing on the bogus `%m` operand; GNU `stat -c` fails cleanly (no stdout) on BSD.
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# Read one field out of the pretty-printed .code_agent_results.json.
result_field() {
    [ -f "$RESULTS_PATH" ] || return 0
    grep -m1 "\"$1\"" "$RESULTS_PATH" 2>/dev/null \
        | sed 's/.*: *//; s/[",]//g; s/^ *//; s/ *$//'
}

result_summary() {
    [ -f "$RESULTS_PATH" ] || return 0
    _ok="$(result_field success)"
    if [ "$_ok" = "true" ]; then _ok="success"; else _ok="failed"; fi
    printf '%s · %s · %s · %s refinement(s) · %s issue(s)' \
        "$_ok" "$(result_field mode)" "$(result_field scenario)" \
        "$(result_field refinements)" "$(result_field issue_count)"
}

# --- Actions: status / stop / wait -------------------------------------------------------------
# These read the project's own files and Docker state, so they work for a run started by anyone —
# a detached plugin run, or an attached run in another terminal — including from a fresh shell
# long after the run began.

# Last RUN/STEP text, last activity text, and the DONE text if the trail ended. Records are
# `+HH:MM:SS  KIND   text` (text starts at column 19); indented lines continue the previous record.
trail_summary() {
    awk '
        /^[ \t]/ { next }
        {
            kind = $2; text = substr($0, 19)
            if (kind == "RUN" || kind == "STEP") step = text
            if (kind == "TEXT" || kind == "TOOL" || kind == "TASK") act = text
            if (kind == "DONE") done = text
        }
        END { printf "%s\n%s\n%s\n", step, act, done }
    ' "$PROGRESS_PATH" 2>/dev/null
}

do_status() {
    # The recent trail first, the one-line summary last, so the last line is always the summary.
    if [ "$TAIL_N" -gt 0 ] && [ -f "$PROGRESS_PATH" ]; then
        tail -n "$TAIL_N" "$PROGRESS_PATH"
    fi
    if run_is_live; then
        _started="$(run_started_epoch)"
        _ago=""
        [ -n "$_started" ] && _ago=" · started $(fmt_elapsed $(( $(date +%s) - _started ))) ago"
        _step=""; _act=""; _done=""
        if [ -f "$PROGRESS_PATH" ]; then
            _sum="$(trail_summary)"
            _step="$(printf '%s\n' "$_sum" | sed -n 1p)"
            _act="$(printf '%s\n' "$_sum" | sed -n 2p)"
            _done="$(printf '%s\n' "$_sum" | sed -n 3p)"
        fi
        if [ -n "$_done" ]; then
            printf 'Finishing · %s\n' "$_done"
        elif [ -n "$_act" ]; then
            # The trail's mtime is the last write, whatever its kind: the run's last sign of life.
            _age="$(fmt_elapsed $(( $(date +%s) - $(file_mtime "$PROGRESS_PATH") )))"
            printf 'Running · %s%s · %s · last: %s (%s ago)\n' "$(run_mode_label)" "$_ago" \
                "${_step:-starting up}" "$_act" "$_age"
        else
            printf 'Running · %s%s · %s\n' "$(run_mode_label)" "$_ago" "${_step:-starting up}"
        fi
        return 0
    fi

    if [ -f "$RESULTS_PATH" ]; then
        printf 'No run in progress. Last result: %s\n' "$(result_summary)"
    else
        printf 'No run in progress for this project, and no previous result.\n'
    fi
}

# Printed after a detached launch. The launcher is the one place that knows its own absolute path
# and the project directory, so the commands come out copy-pasteable for a second terminal: a
# plugin-installed copy lives under a per-host cache path no user could type from memory.
SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
print_background_hints() {
    printf 'Running in the background as a detached container. This session can close; the run continues.\n'
    printf "  follow it live:   tail -f '%s'\n" "$PROGRESS_PATH"
    printf "  wait for it:      cd '%s' && '%s' --wait\n" "$PROJECT_ABS" "$SELF_PATH"
    printf "  status:           cd '%s' && '%s' --status\n" "$PROJECT_ABS" "$SELF_PATH"
    printf "  stop:             cd '%s' && '%s' --stop\n" "$PROJECT_ABS" "$SELF_PATH"
}

do_stop() {
    if run_is_live; then
        docker stop "$RUN_NAME" >/dev/null 2>&1
        printf 'Stopped the run for this project.\n'
    else
        printf 'No run in progress for this project.\n'
    fi
}

# Block until the run ends, then print the line --status prints. `docker wait` blocks on the
# daemon — no polling, nothing printed until the end — and returns the container's exit code
# (0 success, 1 failure, 143 stopped), which becomes this script's. A run that is already gone
# fails it at once; that is swallowed and the status line still says what happened.
do_wait() {
    _rc="$(docker wait "$RUN_NAME" 2>/dev/null)"
    case "$_rc" in ''|*[!0-9]*) _rc=0 ;; esac
    do_status
    return "$_rc"
}

case "$ACTION" in
    status) do_status; exit $? ;;
    stop)   do_stop;   exit $? ;;
    wait)   do_wait;   exit $? ;;
esac

# --- Launch path -------------------------------------------------------------------------------

# Auto-detect mode from input type unless --mode is already present.
#   string/file input → planning mode ; no input → error (mode must be explicit).
# Users can override at any time by passing --mode explicitly.
if [ ${#FORWARD_ARGS[@]} -eq 0 ] || ! printf '%s\n' "${FORWARD_ARGS[@]}" | grep -qE -- '^--mode(=.*)?$'; then
    if [ -n "$REQUIREMENTS" ]; then
        # A requirements string or file path implies planning mode. (Python resolves a file
        # path relative to the project dir, renames it with a timestamp, and adds frontmatter.)
        FORWARD_ARGS=(--mode planning "${FORWARD_ARGS[@]}")
    else
        # No input and no --mode: require explicit mode to avoid silent defaults
        echo "Error: no requirements provided and --mode not specified."
        echo ""
        echo "Usage:"
        echo "  ./codeagent.sh \"Add a metrics endpoint\"          # plan from text"
        echo "  ./codeagent.sh requirements.md                    # plan from file"
        echo "  ./codeagent.sh --mode implementation              # implement from latest ADR"
        echo "  ./codeagent.sh my_adr.md --mode implementation    # implement from specific ADR"
        echo "  ./codeagent.sh \"widen the window\" --mode patch    # small change, no planning"
        exit 1
    fi
fi

# Record the mode as a container label so --status can name what is running without re-deriving it.
# Both spellings are accepted because either can reach us from a user or a calling agent.
RUN_MODE=""
_take_next=0
for _a in "${FORWARD_ARGS[@]}"; do
    if [ "$_take_next" = "1" ]; then RUN_MODE="$_a"; break; fi
    case "$_a" in
        --mode)   _take_next=1 ;;
        --mode=*) RUN_MODE="${_a#--mode=}"; break ;;
    esac
done
[ -z "$RUN_MODE" ] && RUN_MODE="agent"

# Patch mode is defined by its request: there is nothing to resume and nothing to auto-discover.
# Left to discovery it would pick up the newest adr/ file — most often a plan — and run that with
# none of the machinery a plan needs. The Python CLI refuses this too, but only once the container
# is up; with --detach that failure lands after the launcher has already printed a run name, so
# catch it here while the user is still looking at the terminal.
if [ "$RUN_MODE" = "patch" ] && [ -z "$REQUIREMENTS" ]; then
    echo "Error: patch mode requires a request describing the change." >&2
    echo "" >&2
    echo "Usage:" >&2
    echo "  ./codeagent.sh \"widen the aggregation window to 2 hours\" --mode patch" >&2
    echo "  ./codeagent.sh change-notes.md --mode patch" >&2
    exit 1
fi

# --- Preflight ---------------------------------------------------------------------------------
# Everything that can fail before the container exists is checked HERE, synchronously, so a
# detached run either starts for real or reports a usable error inline. Without this, --rm plus
# --detach would turn a bad image or an unreachable daemon into a vanished container and an empty
# log — a failure with nothing to read.
require_docker
# Bootstrap the image if this machine has never run the agent before. Doing it here — before
# anything detaches — is what keeps the "a detached run either starts for real or reports a usable
# error inline" guarantee: a pull that failed after detaching would leave a vanished container and
# an empty log.
if [ -n "${DATASQRL_AGENT_IMAGE:-}" ]; then
    # A custom image could point anywhere, so guessing where to fetch it from would be wrong.
    IMAGE="$DATASQRL_AGENT_IMAGE"
    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        echo "Error: image '$IMAGE' (from DATASQRL_AGENT_IMAGE) is not present locally." >&2
        echo "Build it, pull it, or unset DATASQRL_AGENT_IMAGE to use the published image." >&2
        exit 1
    fi
else
    resolve_edition
    IMAGE="$LOCAL_IMAGE"
    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        echo "Image '$IMAGE' not found." >&2
        ensure_image
    fi
fi

# A container left behind by a run that was started WITHOUT --rm would hold the name forever;
# clear it if it is no longer running, so the lock cannot outlive the run that took it.
if ! run_is_live && [ -n "$(docker ps -aq -f "name=^${RUN_NAME}$" 2>/dev/null)" ]; then
    docker rm "$RUN_NAME" >/dev/null 2>&1
fi

if run_is_live; then
    _started="$(run_started_epoch)"
    if [ -n "$_started" ]; then
        _ago=" (started $(fmt_elapsed $(( $(date +%s) - _started ))) ago)"
    else
        _ago=""
    fi
    echo "Error: a run is already in progress for this project${_ago}." >&2
    echo "" >&2
    echo "Two agents on one project would interleave edits to the same files, so this run was" >&2
    echo "not started. Check on the existing one or stop it:" >&2
    echo "  ./codeagent.sh --status" >&2
    echo "  ./codeagent.sh --stop" >&2
    exit 1
fi

# Set up MCP server to retrieve code samples
# Set local MCP server URL (accessible from Docker via host.docker.internal)
#MCP_SERVER_URL="http://host.docker.internal:8888/v1/mcp"
# Set cloud MCP server
#MCP_SERVER_URL="https://code-agent-datasqrl.api.sqrl.live/v1/mcp"

# --- AWS profile ---------------------------------------------------------------------------------
# An AWS profile reaches the container as ONE temporary credential, exported here on the host.
# The container never gets ~/.aws: that folder can hold long-lived keys and an SSO login for every
# account and role, and the agent runs shell commands.

is_sso_profile() {
    aws configure get sso_session --profile "$1" >/dev/null 2>&1 \
        || aws configure get sso_start_url --profile "$1" >/dev/null 2>&1
}

# Exports a temporary credential for AWS_PROFILE into this process, plus AWS_REGION.
# An expired or missing login stops the run before it starts, naming the command that fixes it.
export_aws_profile_credentials() {
    local profile="$AWS_PROFILE" out=""
    if ! command -v aws >/dev/null 2>&1; then
        echo "Error: AWS_PROFILE=$profile needs the AWS CLI v2 on this machine." >&2
        echo "Install it: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" >&2
        exit 1
    fi
    if ! out="$(aws configure export-credentials --profile "$profile" --format env-no-export 2>/dev/null)" \
       || [ -z "$out" ]; then
        echo "Error: could not get AWS credentials for profile '$profile'." >&2
        if is_sso_profile "$profile"; then
            echo "The AWS login is missing or expired. Log in, then re-run:" >&2
            echo "  aws --profile $profile sso login" >&2
        else
            echo "See why with:" >&2
            echo "  aws configure export-credentials --profile $profile" >&2
        fi
        exit 1
    fi
    # A static profile has no session token, so a stale one from the shell must not ride along.
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    local _k _v
    while IFS='=' read -r _k _v; do
        case "$_k" in
            AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN) export "$_k=$_v" ;;
        esac
    done <<< "$out"
    if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
        echo "Error: the AWS CLI returned no access key for profile '$profile'." >&2
        exit 1
    fi
    if [ -z "${AWS_REGION:-}" ]; then
        AWS_REGION="$(aws configure get region --profile "$profile" 2>/dev/null)"
        export AWS_REGION="${AWS_REGION:-us-east-1}"
    fi
    # The container works from the exported credential alone.
    unset AWS_PROFILE
}

# The coding agent's provider: the --provider flag, else CODING_AGENT_PROVIDER, as in the CLI.
RUN_PROVIDER="${CODING_AGENT_PROVIDER:-}"
_take_next=0
for _a in "${FORWARD_ARGS[@]}"; do
    if [ "$_take_next" = "1" ]; then RUN_PROVIDER="$_a"; break; fi
    case "$_a" in
        --provider)   _take_next=1 ;;
        --provider=*) RUN_PROVIDER="${_a#--provider=}"; break ;;
    esac
done

# AWS_PROFILE is used only by a run that needs AWS: a Bedrock model or an opted-in log upload.
# Many shells export AWS_PROFILE for unrelated work, so any other run ignores it; an expired login
# then never blocks it, and no AWS credential reaches it.
if [ -n "${AWS_PROFILE:-}" ]; then
    case "$RUN_PROVIDER" in
        amazon-bedrock|bedrock) _needs_aws=1 ;;
        *)                      _needs_aws=0 ;;
    esac
    [ "${DATASQRL_TELEMETRY:-}" = "1" ] && _needs_aws=1
    if [ "$_needs_aws" = "1" ] && { [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; }; then
        export_aws_profile_credentials
    else
        # Access keys already in the environment win over a profile, as in the AWS SDK.
        unset AWS_PROFILE
    fi
fi

# Check for authentication (cross-platform)
CREDENTIALS_FILE="$HOME/.claude/.credentials.json"
TEMP_CREDENTIALS=""

# A detached run outlives this script, so a credentials file created here must outlive it too —
# deleting it on exit would pull the mount out from under a container that has only just started.
# Detached runs therefore get a deterministic per-project path (overwritten by the next run on the
# same project, so at most one exists) instead of a mktemp file removed on exit.
write_temp_credentials() {
    if [ "$DETACH" = "1" ]; then
        TEMP_CREDENTIALS="${TMPDIR:-/tmp}/codeagent-creds-${RUN_NAME}.json"
        rm -f "$TEMP_CREDENTIALS"
        (umask 077; printf '%s' "$1" > "$TEMP_CREDENTIALS")
    else
        TEMP_CREDENTIALS="$(mktemp)"
        printf '%s' "$1" > "$TEMP_CREDENTIALS"
        trap 'rm -f "$TEMP_CREDENTIALS"' EXIT
    fi
    CREDENTIALS_FILE="$TEMP_CREDENTIALS"
}

if [ -z "$ANTHROPIC_API_KEY" ]; then
    if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
        # Materialize the OAuth token as a credentials.json so the in-container
        # orchestrator (which only reads ANTHROPIC_API_KEY or ~/.claude/.credentials.json)
        # can use it. Format matches what `claude login` writes.
        write_temp_credentials "$(printf '{"claudeAiOauth":{"accessToken":"%s"}}' "$CLAUDE_CODE_OAUTH_TOKEN")"
    elif [ -f "$CREDENTIALS_FILE" ]; then
        # Linux: credentials stored in file
        :
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS: extract credentials from Keychain
        KEYCHAIN_CREDS=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
        if [ -n "$KEYCHAIN_CREDS" ]; then
            write_temp_credentials "$KEYCHAIN_CREDS"
        fi
    fi

    if [ ! -f "$CREDENTIALS_FILE" ]; then
        echo "Error: No authentication found"
        echo "Set one of the following, then re-run:"
        echo "  - ANTHROPIC_API_KEY  (https://console.anthropic.com/settings/keys)"
        echo "  - CLAUDE_CODE_OAUTH_TOKEN  (run 'claude setup-token' to generate)"
        echo "  - run 'claude login' to write ~/.claude/.credentials.json"
        exit 1
    fi
fi

# Build the container layout.
# The repo goes in read-only so the agent can survey sibling projects/catalogs; the project is
# overlaid read-write on top of it, making it the only place anything can be written. A misdirected
# compile therefore fails loudly (read-only filesystem) instead of silently duplicating the repo.
MOUNT_SPECS=()
if [ "$PROJECT_REL" = "." ]; then
    # Invoked at the repo root: the project IS the repo, so there is nothing to protect from it.
    MOUNT_SPECS+=(-v "$MOUNT_DIR:/workspace")
    CONTAINER_WORKSPACE="/workspace"
else
    MOUNT_SPECS+=(-v "$MOUNT_DIR:/workspace:ro")
    MOUNT_SPECS+=(-v "$MOUNT_DIR/$PROJECT_REL:/workspace/$PROJECT_REL")
    CONTAINER_WORKSPACE="/workspace/$PROJECT_REL"
fi
PROJECT_SUBDIR="$PROJECT_REL"
GATE_WS="$CONTAINER_WORKSPACE"

# Capture host identifiers for log correlation across planning/implementation runs
HOST_WORKSPACE_FOLDER=$(basename "$HOST_WS")
if [[ "$OSTYPE" == "darwin"* ]]; then
    HOST_MAC_ID=$(ifconfig en0 2>/dev/null | awk '/ether/{print $2; exit}')
    [ -z "$HOST_MAC_ID" ] && HOST_MAC_ID=$(ifconfig 2>/dev/null | awk '/ether/{print $2; exit}')
else
    HOST_MAC_ID=$(ip link show 2>/dev/null | awk '/link\/ether/{print $2; exit}')
    [ -z "$HOST_MAC_ID" ] && HOST_MAC_ID=$(cat /sys/class/net/"$(ls /sys/class/net/ 2>/dev/null | grep -v lo | head -1)"/address 2>/dev/null)
fi

# Build docker arguments.
# --name is the per-project lock (see "Run identity" above) and is applied in BOTH modes on
# purpose: if only detached runs were named, a manual attached run could still start on top of a
# plugin run, which is exactly the collision the lock exists to prevent.
DOCKER_ARGS=(
  --rm
  --name "$RUN_NAME"
  --label "codeagent.started=$(date +%s)"
  --label "codeagent.mode=$RUN_MODE"
  "${MOUNT_SPECS[@]}"
)

if [ "$DETACH" = "1" ]; then
  DOCKER_ARGS+=(-d)
fi

# Pass MCP server URL if set
if [ -n "$MCP_SERVER_URL" ]; then
  DOCKER_ARGS+=(-e MCP_SERVER_URL="$MCP_SERVER_URL")
fi

# Mount credentials file if it exists
if [ -f "$CREDENTIALS_FILE" ]; then
  DOCKER_ARGS+=(-v "$CREDENTIALS_FILE:/root/.claude/.credentials.json:ro")
fi

# --- Model provider settings -------------------------------------------------------------------
# The container gets these variables by NAME and nothing else from the host environment. The
# agent runs arbitrary shell commands and its log can be uploaded to remote storage, so an
# unrelated secret in the caller's shell has no business inside it. Host PATH, HOME and JAVA_HOME
# would also replace the image's own values.
#
# `-e NAME` copies the host value only when the variable is set, and keeps the value out of the
# `docker run` argument list that `ps` shows.
#
# The Pi names follow https://pi.dev/docs/latest/providers. test-docker-local.sh checks every
# variable the image's Pi documents against this list, so a Pi upgrade cannot drift from it.
PROVIDER_ENV_VARS=(
  # Anthropic (also the judges) and Anthropic-compatible endpoints
  ANTHROPIC_API_KEY ANTHROPIC_OAUTH_TOKEN ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL
  ANTHROPIC_CUSTOM_HEADERS CLAUDE_CODE_OAUTH_TOKEN
  # Anthropic workload identity federation (Pi only; the judges still need a key or login)
  ANTHROPIC_FEDERATION_RULE_ID ANTHROPIC_ORGANIZATION_ID ANTHROPIC_IDENTITY_TOKEN_FILE
  ANTHROPIC_SERVICE_ACCOUNT_ID ANTHROPIC_WORKSPACE_ID
  # Pi providers with a single API key
  ANT_LING_API_KEY OPENAI_API_KEY DEEPSEEK_API_KEY NVIDIA_API_KEY GEMINI_API_KEY
  COPILOT_GITHUB_TOKEN MISTRAL_API_KEY GROQ_API_KEY CEREBRAS_API_KEY XAI_API_KEY
  OPENROUTER_API_KEY AI_GATEWAY_API_KEY ZAI_API_KEY ZAI_CODING_CN_API_KEY OPENCODE_API_KEY
  RADIUS_API_KEY TYPESAFE_API_KEY HF_TOKEN FIREWORKS_API_KEY TOGETHER_API_KEY BASETEN_API_KEY
  KIMI_API_KEY META_API_KEY MINIMAX_API_KEY MINIMAX_CN_API_KEY MOONSHOT_API_KEY
  QWEN_TOKEN_PLAN_API_KEY QWEN_TOKEN_PLAN_CN_API_KEY XIAOMI_API_KEY
  XIAOMI_TOKEN_PLAN_CN_API_KEY XIAOMI_TOKEN_PLAN_AMS_API_KEY XIAOMI_TOKEN_PLAN_SGP_API_KEY
  # Azure OpenAI
  AZURE_OPENAI_API_KEY AZURE_OPENAI_BASE_URL AZURE_OPENAI_RESOURCE_NAME
  # Amazon Bedrock (with DATASQRL_TELEMETRY=1, the access keys also upload the run log)
  AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_BEARER_TOKEN_BEDROCK
  AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION AWS_ROLE_ARN AWS_ROLE_SESSION_NAME
  AWS_WEB_IDENTITY_TOKEN_FILE AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE
  # Google Vertex AI
  GOOGLE_CLOUD_API_KEY GOOGLE_CLOUD_PROJECT GCLOUD_PROJECT GOOGLE_CLOUD_LOCATION
  GOOGLE_APPLICATION_CREDENTIALS
  # Cloudflare AI Gateway and Workers AI
  CLOUDFLARE_API_KEY CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_GATEWAY_ID
  # Claude Code's own cloud modes (--agent claude-code)
  CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
  ANTHROPIC_VERTEX_PROJECT_ID CLOUD_ML_REGION
  ANTHROPIC_FOUNDRY_API_KEY ANTHROPIC_FOUNDRY_RESOURCE ANTHROPIC_FOUNDRY_BASE_URL
  # Model selection, the environment form of --model and --provider
  CODING_AGENT_MODEL CODING_AGENT_PROVIDER
  # Telemetry, opt-in and off by default: uploads the run log for troubleshooting and debugging
  DATASQRL_TELEMETRY
  # Claude Code on Bedrock with a credential no variable names (an EC2 instance role)
  DATASQRL_AGENT_AWS_CHAIN
)
# ECS task credentials come as a family of variables that share this prefix.
while IFS= read -r _name; do
  PROVIDER_ENV_VARS+=("$_name")
done < <(compgen -e | grep '^AWS_CONTAINER_CREDENTIALS_')

# DATASQRL_AGENT_PASS_ENV adds names this list lacks, comma-separated: a newer Pi provider, or a
# custom provider's key from ~/.pi/agent/models.json.
IFS=',' read -r -a _extra_env <<< "${DATASQRL_AGENT_PASS_ENV:-}"
for _name in "${_extra_env[@]}"; do
  _name="${_name// /}"
  [ -z "$_name" ] && continue
  if [[ ! "$_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "Error: DATASQRL_AGENT_PASS_ENV holds '$_name', which is not a variable name." >&2
    exit 1
  fi
  PROVIDER_ENV_VARS+=("$_name")
done

for _name in "${PROVIDER_ENV_VARS[@]}"; do
  [ -n "${!_name+set}" ] && DOCKER_ARGS+=(-e "$_name")
done

# Variables that hold a PATH need the file too. It is mounted read-only at the same path, so the
# variable stays valid inside the container unchanged.
for _name in GOOGLE_APPLICATION_CREDENTIALS AWS_WEB_IDENTITY_TOKEN_FILE \
             AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE ANTHROPIC_IDENTITY_TOKEN_FILE; do
  _path="${!_name:-}"
  [ -n "$_path" ] || continue
  if [ ! -f "$_path" ]; then
    echo "Error: $_name points at '$_path', which is not a file." >&2
    exit 1
  fi
  DOCKER_ARGS+=(-v "$_path:$_path:ro")
done

# Vertex AI with Application Default Credentials (`gcloud auth application-default login`):
# the Google SDKs find that file at a fixed path under the home directory.
_adc="$HOME/.config/gcloud/application_default_credentials.json"
if [ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && [ -f "$_adc" ] \
   && [ -n "${GOOGLE_CLOUD_PROJECT:-}${GCLOUD_PROJECT:-}${ANTHROPIC_VERTEX_PROJECT_ID:-}" ]; then
  DOCKER_ARGS+=(-v "$_adc:/root/.config/gcloud/application_default_credentials.json:ro")
fi

# Scope the large-data hard gate (cmd.sh) to the PROJECT dir, so read-only shared siblings
# mounted alongside it are never scanned/blocked (the agent cannot shrink a read-only module).
DOCKER_ARGS+=(-e WORKSPACE_DIR="$GATE_WS")

# Host identifiers for log correlation
DOCKER_ARGS+=(-e HOST_WORKSPACE_FOLDER="$HOST_WORKSPACE_FOLDER")
if [ -n "$HOST_MAC_ID" ]; then
  DOCKER_ARGS+=(-e HOST_MAC_ID="$HOST_MAC_ID")
fi

# CLI arguments that codeagent.sh owns (container paths for the reconstructed layout).
# Appended last so they win over any stray user-passed duplicates.
CLI_TAIL=(--workspace "$CONTAINER_WORKSPACE" --project-subdir "$PROJECT_SUBDIR")

# Build agent arguments - forward requirements (if non-empty) and any extra CLI args.
# When REQUIREMENTS is empty, omit it so Python can auto-discover
# the latest adr/plan_*.md in the project.
if [ -n "$REQUIREMENTS" ]; then
    AGENT_ARGS=("$REQUIREMENTS" "${FORWARD_ARGS[@]}" "${CLI_TAIL[@]}")
else
    AGENT_ARGS=("${FORWARD_ARGS[@]}" "${CLI_TAIL[@]}")
fi

# Run the agent
if [ "$DETACH" = "1" ]; then
    if docker run "${DOCKER_ARGS[@]}" "$IMAGE" "${AGENT_ARGS[@]}" >/dev/null; then
        echo "$RUN_NAME"
        print_background_hints
    else
        # The container never started, so nothing will ever consume the credentials file.
        [ -n "$TEMP_CREDENTIALS" ] && rm -f "$TEMP_CREDENTIALS"
        exit 1
    fi
else
    docker run "${DOCKER_ARGS[@]}" "$IMAGE" "${AGENT_ARGS[@]}"
fi
