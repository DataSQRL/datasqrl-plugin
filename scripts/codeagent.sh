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
#   --watch    Emit coarse, human-readable progress lines for this project's run (one per
#              line) and exit when the run reaches a terminal state. Safe for attached runs
#              started from another terminal.
#   --status   Print a one-shot status line: the in-flight run, or the last run's result.
#   --stop     Stop this project's in-flight run.
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
# writes (e.g. "script.shared": {"path": "../data-catalog"}) is equally valid in your real repo.
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
# Required environment variables:
#   - AWS_ACCESS_KEY_ID
#   - AWS_SECRET_ACCESS_KEY

# The image every run uses. This is the same local name `build-docker-local.sh` produces and
# `test-docker-local.sh` validates, so a local build is picked up with no extra flag.
#
# No registry serves this name, so preflight bootstraps it from the published image (pull + tag)
# when it is missing — the two commands users previously had to run by hand.
DEFAULT_IMAGE="datasqrl-code-agent:latest"
PUBLISHED_IMAGE="ghcr.io/datasqrl/code-agent:latest"
IMAGE="${CODEAGENT_IMAGE:-$DEFAULT_IMAGE}"

# --- Argument partitioning ---------------------------------------------------------------------
# Lifetime flags are consumed here and MUST NOT reach the Python CLI, which does not know them.
# Everything else is left in place for the requirements/forwarding split below.
DETACH=0
ACTION="run"
REST_ARGS=()
for _arg in "$@"; do
    case "$_arg" in
        --detach) DETACH=1 ;;
        --watch)  ACTION="watch" ;;
        --status) ACTION="status" ;;
        --stop)   ACTION="stop" ;;
        *)        REST_ARGS+=("$_arg") ;;
    esac
done
set -- "${REST_ARGS[@]}"

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
# makes --rm safe and lets --status re-attach to a run from a different shell or a later session.
LOG_PATH="$PROJECT_ABS/.claude/codeagent_logs.jsonl.bak"
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

# Extract a string / integer field from one line of JSON. The log is one JSON object per line and
# every inner quote is escaped by json.dumps, so a naive match cannot run past the field it wants.
json_str() {
    printf '%s' "$1" | sed -n "s/.*\"$2\": \"\\([^\"]*\\)\".*/\\1/p" | head -1
}
json_num() {
    printf '%s' "$1" | sed -n "s/.*\"$2\": \\(-\\{0,1\\}[0-9][0-9]*\\).*/\\1/p" | head -1
}

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

# --- Progress vocabulary -----------------------------------------------------------------------
# The ONLY user-facing description of what a run is doing. The underlying log is an implementation
# detail: it is far too detailed to show, and its shape is free to change as long as this function
# keeps producing the same handful of lines. Everything not matched here is silently dropped.
#
# Failure states are matched deliberately. A watcher that only knows the happy path goes quiet on a
# crash, and quiet is indistinguishable from "still working" — the user would wait forever.
WATCH_ITER=""
render_milestone() {
    _line="$1"
    _msg=""

    # The coding agent's own output is relayed verbatim under this type. It is the bulk of the log
    # and none of it is a milestone; drop it before any other matching.
    case "$_line" in
        *'"type": "logs"'*|*'"type": "agent_prompt"'*|*'"type": "metrics"'*|*'"type": "agent_metrics"'*)
            return 0 ;;
    esac

    case "$_line" in
        *'"type": "run_result"'*)
            printf 'Finished · %s\n' "$(result_summary)"
            return 2 ;;
        *'"message": "Run starting"'*)
            _mode="$(json_str "$_line" mode)"
            printf 'Run started · %s\n' "${_mode:-agent}"
            return 0 ;;
        *'"message": "Iteration '*)
            WATCH_ITER="$(json_str "$_line" message | sed 's/[^0-9]//g')"
            printf 'Iteration %s · implementing\n' "${WATCH_ITER:-?}"
            return 0 ;;
        *'"message": "Running tests"'*)
            printf 'Iteration %s · running tests\n' "${WATCH_ITER:-?}"
            return 0 ;;
        *'"message": "Test execution failed"'*)
            printf 'Iteration %s · tests failed, retrying\n' "${WATCH_ITER:-?}"
            return 0 ;;
        *'"message": "Running '*' judges"'*)
            printf 'Iteration %s · verifying\n' "${WATCH_ITER:-?}"
            return 0 ;;
        *'"source": "refinement"'*)
            printf 'Iteration %s · verified (%s issue(s))\n' \
                "${WATCH_ITER:-?}" "$(json_num "$_line" issue_count)"
            return 0 ;;
        *'"source": "finalize"'*)
            printf 'Finalizing\n'
            return 0 ;;
        *'"level": "CRITICAL"'*)
            _msg="$(json_str "$_line" message)"
            printf 'Error · %s\n' "${_msg:-unknown error}"
            return 0 ;;
    esac
    return 0
}

# --- Actions: watch / status / stop ------------------------------------------------------------
# These read the project's own files and Docker state, so they work for a run started by anyone —
# a detached plugin run, or an attached run in another terminal — including from a fresh shell
# long after the run began.

count_lines() {
    if [ -f "$1" ]; then
        _n="$(wc -l < "$1" 2>/dev/null | tr -d ' ')"
        printf '%s' "${_n:-0}"
    else
        printf '0'
    fi
}

# Inode of the log, used to notice the container replacing it. Portable across BSD/GNU `ls`.
log_inode() {
    ls -i "$LOG_PATH" 2>/dev/null | awk '{print $1}'
}

# Emit milestones for lines after $1 in the log; sets _drained to the new line count.
# Runs in the CURRENT shell (input redirected, never piped) so WATCH_ITER accumulates across
# batches — in a subshell every batch would restart at an unknown iteration.
drain_log() {
    _from="$1"
    _drained="$_from"
    _total="$(count_lines "$LOG_PATH")"
    [ "$_total" -gt "$_from" ] || return 0
    tail -n +$((_from + 1)) "$LOG_PATH" > "$_batch" 2>/dev/null
    _drained="$_total"
    while IFS= read -r _l; do
        if ! render_milestone "$_l"; then
            return 1     # terminal event rendered
        fi
    done < "$_batch"
    return 0
}

do_watch() {
    # Skip whatever is already in the log so a re-watch mid-run does not replay old milestones.
    _seen="$(count_lines "$LOG_PATH")"
    _inode="$(log_inode)"
    _batch="$(mktemp)"
    _saw_live=0
    _waited=0
    trap 'rm -f "$_batch"' EXIT

    while :; do
        if run_is_live; then _saw_live=1; fi

        # The container rotates the previous run's log aside on startup and creates a new one.
        # A changed inode (or a file that shrank) means we are now looking at a different file,
        # so the offset we were holding belongs to the old one: start again from its first line.
        _now_inode="$(log_inode)"
        if [ "$_now_inode" != "$_inode" ] || [ "$(count_lines "$LOG_PATH")" -lt "$_seen" ]; then
            _inode="$_now_inode"
            _seen=0
        fi

        if ! drain_log "$_seen"; then rm -f "$_batch"; exit 0; fi
        _seen="$_drained"

        if [ "$_saw_live" -eq 1 ] && ! run_is_live; then
            # Container is gone. Give the final writes a beat to land, drain once more, then decide.
            sleep 2
            if ! drain_log "$_seen"; then rm -f "$_batch"; exit 0; fi
            printf 'Error · run ended without writing a result\n'
            rm -f "$_batch"
            exit 1
        fi

        # Never seen alive. Either nothing was started, or (rarely) the run began and ended inside
        # the gap between --detach returning and this watch attaching, in which case its milestones
        # were already in the log when we took our starting offset and are not replayed.
        if [ "$_saw_live" -eq 0 ]; then
            _waited=$((_waited + 5))
            if [ "$_waited" -ge 60 ]; then
                printf 'Error · no run in progress (nothing started, or it ended before the watch attached)\n'
                rm -f "$_batch"
                exit 1
            fi
        fi

        sleep 5
    done
}

do_status() {
    if run_is_live; then
        _started="$(run_started_epoch)"
        if [ -n "$_started" ]; then
            _ago=" · started $(fmt_elapsed $(( $(date +%s) - _started ))) ago"
        else
            _ago=""
        fi
        # Replay the whole log and keep only the final milestone. The loop is redirected rather
        # than piped so WATCH_ITER carries forward and iteration numbers come out right.
        _last=""
        if [ -f "$LOG_PATH" ]; then
            _tmp="$(mktemp)"
            while IFS= read -r _l; do
                render_milestone "$_l"
            done < "$LOG_PATH" > "$_tmp" 2>/dev/null
            _last="$(tail -1 "$_tmp" 2>/dev/null)"
            rm -f "$_tmp"
        fi
        if [ -n "$_last" ]; then
            printf 'Running · %s%s · %s\n' "$(run_mode_label)" "$_ago" "$_last"
        else
            printf 'Running · %s%s · starting up\n' "$(run_mode_label)" "$_ago"
        fi
        return 0
    fi

    if [ -f "$RESULTS_PATH" ]; then
        printf 'No run in progress. Last result: %s\n' "$(result_summary)"
    else
        printf 'No run in progress for this project, and no previous result.\n'
    fi
}

do_stop() {
    if run_is_live; then
        docker stop "$RUN_NAME" >/dev/null 2>&1
        printf 'Stopped the run for this project.\n'
    else
        printf 'No run in progress for this project.\n'
    fi
}

case "$ACTION" in
    watch)  do_watch;  exit $? ;;
    status) do_status; exit $? ;;
    stop)   do_stop;   exit $? ;;
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
if ! command -v docker >/dev/null 2>&1; then
    echo "Error: docker is not installed or not on PATH." >&2
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "Error: cannot talk to the Docker daemon. Is Docker running?" >&2
    exit 1
fi
# Bootstrap the image if this machine has never run the agent before. Doing it here — before
# anything detaches — is what keeps the "a detached run either starts for real or reports a usable
# error inline" guarantee: a pull that failed after detaching would leave a vanished container and
# an empty log.
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    # Only the default name can be bootstrapped: it is an alias we know how to produce. A custom
    # CODEAGENT_IMAGE could point anywhere, so guessing where to fetch it from would be wrong.
    if [ "$IMAGE" != "$DEFAULT_IMAGE" ]; then
        echo "Error: image '$IMAGE' (from CODEAGENT_IMAGE) is not present locally." >&2
        echo "Build it, pull it, or unset CODEAGENT_IMAGE to use the published image." >&2
        exit 1
    fi

    echo "Image '$IMAGE' not found; fetching it from $PUBLISHED_IMAGE (first run only, ~3GB)..." >&2
    if ! docker pull "$PUBLISHED_IMAGE"; then
        echo "" >&2
        echo "Error: could not pull '$PUBLISHED_IMAGE'." >&2
        echo "" >&2
        echo "If the pull was denied, the package is private and Docker needs to authenticate." >&2
        echo "Create a GitHub personal access token (classic) with the 'read:packages' scope at" >&2
        echo "https://github.com/settings/tokens, then:" >&2
        echo "" >&2
        echo "  echo \"\$GITHUB_PAT\" | docker login ghcr.io -u <your-github-username> --password-stdin" >&2
        echo "" >&2
        echo "Then re-run this command." >&2
        exit 1
    fi
    if ! docker tag "$PUBLISHED_IMAGE" "$IMAGE"; then
        echo "Error: pulled '$PUBLISHED_IMAGE' but could not tag it as '$IMAGE'." >&2
        exit 1
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

# Pass API key if set (takes precedence over credentials file)
if [ -n "$ANTHROPIC_API_KEY" ]; then
  DOCKER_ARGS+=(-e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY")
fi

# Pass OAuth token if set
if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
  DOCKER_ARGS+=(-e CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN")
fi

# Pass AWS credentials (validated inside container)
if [ -n "$AWS_ACCESS_KEY_ID" ]; then
  DOCKER_ARGS+=(-e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID")
fi
if [ -n "$AWS_SECRET_ACCESS_KEY" ]; then
  DOCKER_ARGS+=(-e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY")
fi

# DeepSeek / alternative provider support
if [ -n "$ANTHROPIC_BASE_URL" ]; then
  DOCKER_ARGS+=(-e ANTHROPIC_BASE_URL="$ANTHROPIC_BASE_URL")
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
    else
        # The container never started, so nothing will ever consume the credentials file.
        [ -n "$TEMP_CREDENTIALS" ] && rm -f "$TEMP_CREDENTIALS"
        exit 1
    fi
else
    docker run "${DOCKER_ARGS[@]}" "$IMAGE" "${AGENT_ARGS[@]}"
fi
