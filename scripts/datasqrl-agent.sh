#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Run DataSQRL Code Agent with local or cloud MCP server.
# Run this script from the workspace directory containing your DataSQRL project.
#
# Usage: ./datasqrl-agent.sh <requirements> [options...]
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
#   --image-exists  Print whether the selected edition's image is local and checked; exit 0 or 1.
#                   Never pulls.
#   --show-options [ID]  Print the harnesses, providers and default models the selected image offers,
#                   which variables each provider needs, and whether each is set (never a value).
#                   With ID or --provider ID, that provider alone. Takes --harness for another
#                   harness's providers.
#                   Never pulls.
#   --check-config  Print the harness, provider and model a run would use (--harness, --provider,
#                   --model and the environment applied) and whether their credentials are ready.
#                   For Bedrock it also checks the AWS profile: it lists the profiles when none is
#                   set and names the login command when the SSO login has expired. Ends with
#                   Status READY or NOT READY; exits 0 or 1. Never pulls, never prints a value.
#
# The image flags work in any directory. --pull-image and --image-exists take no other argument. The edition is os unless
# DATASQRL_AGENT_EDITION=pro, DATASQRL_PRO_TOKEN is set, or pro-agent:latest is already exist.
# The pro image and its signature are private, so every pro pull needs a ghcr.io login from a
# GitHub account with pro access: DATASQRL_PRO_TOKEN, a GitHub token with read:packages, or else
# the ghcr.io login that `docker login ghcr.io` stored.
#
# Every pull is checked: cosign verifies that DataSQRL's release workflow on main signed the image,
# and the launcher runs only an image it verified on this machine. The check needs network access
# to Sigstore (sigstore.dev). DATASQRL_AGENT_IMAGE runs a local image, such as a local build,
# without the check.
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
# Set DATASQRL_AGENT_ALLOW_NO_GIT=1 to bypass the git requirement (CI/automation only); the current
# directory is then treated as a standalone single project.
#
# Authentication for an Anthropic run (no --provider, --provider anthropic, or a bare model).
# A run on another provider needs only that provider's variables, such as FIREWORKS_API_KEY.
# In order of precedence:
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

# The images. Each edition is published under its own name and runs under a short local tag.
# Preflight pulls the published image and tags it when the local tag is missing. Every pull is
# checked: the launcher runs only an image whose signature it verified on this machine, and it
# runs that image by its ID. A local build from `build-docker-local.sh` gets its own tag
# (adv-agent:local, pro-agent:local) and no signature, so it runs only through DATASQRL_AGENT_IMAGE.
OS_REGISTRY_IMAGE="ghcr.io/datasqrl/adv-agent:latest"
OS_LOCAL_IMAGE="adv-agent:latest"
PRO_REGISTRY_IMAGE="ghcr.io/datasqrl/pro-agent:latest"
PRO_LOCAL_IMAGE="pro-agent:latest"
# A name for people typing `docker run` by hand: the pro image when there is one, else os.
# Runs never use it, since it moves with whichever edition was pulled.
COMMON_IMAGE="datasqrl-agent:latest"

# The signature check. CI signs each published image with keyless cosign, so a valid signature
# names DataSQRL's release workflow on main. The cosign image is pinned by digest, because a tag
# can move and this image decides what the launcher trusts.
COSIGN_IMAGE="ghcr.io/sigstore/cosign/cosign:v3.1.4@sha256:0f06154836d2de34f887a5c273506d52ca43edaa1d9e53e6510fa78a48f69c2d"
SIGNER_IDENTITY="https://github.com/DataSQRL/code-agent/.github/workflows/build-and-push.yml@refs/heads/main"
SIGNER_ISSUER="https://token.actions.githubusercontent.com"
# The IDs of the images whose signature this machine verified, one per line.
LAUNCHER_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/datasqrl-agent"
VERIFIED_IMAGES_FILE="$LAUNCHER_STATE_DIR/verified-images"

# The temporary files and folders this run removes when it exits. Bash runs the EXIT trap also
# after Ctrl-C, SIGTERM and SIGHUP. Bash keeps one trap per signal, so every temporary path goes
# into this one list instead of into a trap of its own.
PATHS_TO_REMOVE_ON_EXIT=()
remove_paths_on_exit() {
    [ "${#PATHS_TO_REMOVE_ON_EXIT[@]}" -eq 0 ] || rm -rf "${PATHS_TO_REMOVE_ON_EXIT[@]}"
}
trap remove_paths_on_exit EXIT

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
# Sets GHCR_LOGIN_USER and GHCR_LOGIN_SECRET, which the signature check needs too. With the token
# set, every pro pull logs in again, so the token wins over an older stored login.
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
    GHCR_LOGIN_USER="$_user"
    GHCR_LOGIN_SECRET="$DATASQRL_PRO_TOKEN"
    echo "Logged in to ghcr.io as $_user." >&2
}

# Reads the ghcr.io login that `docker login ghcr.io` stored, in the order Docker uses: the
# credHelpers entry for ghcr.io, then credsStore, then an inline auths entry. Docker Desktop keeps
# the login in a credential helper, so the pull can use it, but the cosign container cannot.
# Sets GHCR_LOGIN_USER and GHCR_LOGIN_SECRET and returns 0, or returns 1 when Docker has no ghcr.io
# login. The secret stays in this process: it is never a command argument and never printed.
read_stored_ghcr_login() {
    local _docker_config_file="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
    local _config_contents _credential_helper _helper_reply _inline_auth _decoded_auth
    [ -f "$_docker_config_file" ] || return 1
    # The values read here hold no white space, so the config can be matched as one line.
    _config_contents="$(tr -d ' \t\r\n' < "$_docker_config_file")"
    _credential_helper="$(printf '%s' "$_config_contents" | grep -o '"credHelpers":{[^}]*}' \
        | grep -o '"ghcr.io":"[^"]*"' | head -1 | cut -d'"' -f4)"
    if [ -z "$_credential_helper" ]; then
        _credential_helper="$(printf '%s' "$_config_contents" | grep -o '"credsStore":"[^"]*"' \
            | head -1 | cut -d'"' -f4)"
    fi
    if [ -n "$_credential_helper" ]; then
        # A helper is the program docker-credential-<name> on PATH, so a name is never a path.
        case "$_credential_helper" in *[!A-Za-z0-9._-]*) return 1 ;; esac
        command -v "docker-credential-$_credential_helper" >/dev/null 2>&1 || return 1
        _helper_reply="$(printf 'ghcr.io' | "docker-credential-$_credential_helper" get 2>/dev/null \
            | tr -d ' \t\r\n')"
        GHCR_LOGIN_USER="$(printf '%s' "$_helper_reply" | grep -o '"Username":"[^"]*"' | head -1 | cut -d'"' -f4)"
        GHCR_LOGIN_SECRET="$(printf '%s' "$_helper_reply" | grep -o '"Secret":"[^"]*"' | head -1 | cut -d'"' -f4)"
    else
        _inline_auth="$(printf '%s' "$_config_contents" | grep -o '"ghcr.io":{[^}]*}' \
            | grep -o '"auth":"[^"]*"' | head -1 | cut -d'"' -f4)"
        [ -n "$_inline_auth" ] || return 1
        # GNU and current macOS decode with -d. Older macOS knows only -D.
        _decoded_auth="$(printf '%s' "$_inline_auth" | base64 -d 2>/dev/null)" \
            || _decoded_auth="$(printf '%s' "$_inline_auth" | base64 -D 2>/dev/null)" \
            || return 1
        GHCR_LOGIN_USER="${_decoded_auth%%:*}"
        GHCR_LOGIN_SECRET="${_decoded_auth#*:}"
    fi
    [ -n "$GHCR_LOGIN_USER" ] && [ -n "$GHCR_LOGIN_SECRET" ]
}

# Exit 0 when this machine verified the signature of the image with ID $1.
is_verified_image() {
    [ -n "$1" ] && [ -f "$VERIFIED_IMAGES_FILE" ] && grep -qxF "$1" "$VERIFIED_IMAGES_FILE"
}

# Adds image ID $1 to the record. A record that cannot be written costs a new pull and check on the
# next run, not this run, so it is a warning.
record_verified_image() {
    is_verified_image "$1" && return 0
    if ! { mkdir -p "$LAUNCHER_STATE_DIR" && printf '%s\n' "$1" >> "$VERIFIED_IMAGES_FILE"; } 2>/dev/null; then
        echo "Warning: could not write $VERIFIED_IMAGES_FILE, so the next run checks this image again." >&2
    fi
}

# Prints the digest that `docker pull` recorded for $1, a registry image such as
# ghcr.io/datasqrl/adv-agent:latest. An image can carry digests for several names, so only the one
# for the pulled repository counts.
pulled_digest() {
    docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$1" 2>/dev/null \
        | grep "^${1%:*}@" | head -1 | cut -d@ -f2
}

# Verifies that DataSQRL's release workflow on main signed $1@$2, for example
# ghcr.io/datasqrl/pro-agent@sha256:... It runs the pinned cosign image. The pro signature is as
# private as the pro image, so cosign needs a login: it reads it from a Docker config file that
# exists only for this check. A file keeps the token out of every command's arguments, and a
# folder under the home directory is one that every Docker setup shares with containers.
# Returns 0 when the signature is valid, 1 when the image has no valid signature from that
# workflow, and 2 when the check could not decide, for example after a network error.
verify_image_signature() {
    local _repository="$1" _digest="$2" _auth_dir="" _out _rc
    local _cosign_args=(--rm --user "$(id -u):$(id -g)" -e HOME=/tmp)
    if [ "$RUN_EDITION" = "pro" ]; then
        mkdir -p "$LAUNCHER_STATE_DIR" 2>/dev/null
        if ! _auth_dir="$(mktemp -d "$LAUNCHER_STATE_DIR/cosign-auth.XXXXXX" 2>/dev/null)"; then
            echo "Error: could not make a folder in $LAUNCHER_STATE_DIR for the signature check." >&2
            return 2
        fi
        # Each check removes only its own folder. Another launcher can be in its own check now,
        # and its folder holds the login that check needs.
        PATHS_TO_REMOVE_ON_EXIT+=("$_auth_dir")
        chmod 700 "$_auth_dir"
        (
            umask 077
            printf '{"auths":{"ghcr.io":{"auth":"%s"}}}\n' \
                "$(printf '%s:%s' "$GHCR_LOGIN_USER" "$GHCR_LOGIN_SECRET" | base64 | tr -d '\n')" \
                > "$_auth_dir/config.json"
        )
        _cosign_args+=(-v "$_auth_dir:/cosign-auth:ro" -e DOCKER_CONFIG=/cosign-auth)
    fi
    echo "Checking the signature of $_repository@$_digest..." >&2
    _out="$(docker run "${_cosign_args[@]}" "$COSIGN_IMAGE" verify \
        --certificate-identity "$SIGNER_IDENTITY" \
        --certificate-oidc-issuer "$SIGNER_ISSUER" \
        "$_repository@$_digest" 2>&1 >/dev/null)"
    _rc=$?
    [ -n "$_auth_dir" ] && rm -rf "$_auth_dir"
    if [ "$_rc" = "0" ]; then
        echo "Signature verified: DataSQRL's release workflow built this image on main." >&2
        return 0
    fi
    echo "" >&2
    echo "Error: the signature check failed for $_repository@$_digest, so the launcher will not run it." >&2
    if printf '%s' "$_out" | grep -qiE 'no signatures found|no matching signatures|none of the expected identities'; then
        echo "The image has no signature from DataSQRL's release workflow. Do not run it. Report this to DataSQRL." >&2
        echo "cosign said: $(printf '%s\n' "$_out" | grep -v '^WARNING' | tail -1)" >&2
        return 1
    fi
    if printf '%s' "$_out" | grep -qiE 'sigstore|tuf|rekor|fulcio|dial tcp|no such host|timeout|connection refused'; then
        echo "The check needs network access to Sigstore (sigstore.dev) and to ghcr.io. Check the network, then run again." >&2
    fi
    echo "cosign said: $(printf '%s\n' "$_out" | grep -v '^WARNING' | tail -1)" >&2
    return 2
}

# Makes sure the pinned cosign image is local before the agent image is pulled. It is about 60MB,
# so a download problem shows here, with its progress, and stops the launcher before the agent
# image of about 3GB.
ensure_cosign_image() {
    docker image inspect "$COSIGN_IMAGE" >/dev/null 2>&1 && return 0
    echo "Pulling the signature checker (cosign, about 60MB)..." >&2
    if ! docker pull "$COSIGN_IMAGE" >&2; then
        echo "" >&2
        echo "Error: could not pull the signature checker '$COSIGN_IMAGE'." >&2
        echo "Every pull is checked with it, so the launcher pulls no agent image without it." >&2
        echo "Check the network access to ghcr.io, then run again." >&2
        exit 1
    fi
}

# Pulls REGISTRY_IMAGE, verifies its signature, tags it as LOCAL_IMAGE and records its ID. Sets
# CHECKED_IMAGE_ID. A failed pull or check stops the launcher. An image without a valid signature
# is removed. After a check that could not decide, the image stays, so the next try needs no new
# download. Untagged and unrecorded, it cannot run. It never switches to the other edition,
# because that would give a pro user the os image.
ensure_image() {
    local _digest _signature_check_result
    GHCR_LOGIN_SOURCE=""
    if [ "$RUN_EDITION" = "pro" ]; then
        if [ -n "${DATASQRL_PRO_TOKEN:-}" ]; then
            pro_login
            GHCR_LOGIN_SOURCE="token"
        elif read_stored_ghcr_login; then
            GHCR_LOGIN_SOURCE="stored"
            echo "Using the ghcr.io login that Docker stored for $GHCR_LOGIN_USER." >&2
        else
            echo "Error: the pro image and its signature are private, so a pro pull needs a ghcr.io login." >&2
            echo "" >&2
            echo "If DataSQRL has given your own GitHub account access to the pro edition, log Docker in" >&2
            echo "once with that account and a personal access token (classic) with the 'read:packages' scope:" >&2
            echo "  docker login ghcr.io" >&2
            echo "" >&2
            echo "Or set DATASQRL_PRO_TOKEN to the token DataSQRL gave you. Set it in the shell that starts" >&2
            echo "your coding agent, for example in ~/.zshrc." >&2
            echo "To run the open-source edition instead, set DATASQRL_AGENT_EDITION=os." >&2
            exit 1
        fi
    fi
    ensure_cosign_image
    echo "Pulling $REGISTRY_IMAGE ($RUN_EDITION edition, ~3GB the first time)..." >&2
    if ! docker pull "$REGISTRY_IMAGE"; then
        echo "" >&2
        echo "Error: could not pull '$REGISTRY_IMAGE'." >&2
        if [ "$GHCR_LOGIN_SOURCE" = "token" ]; then
            echo "" >&2
            echo "The login worked, so the token's GitHub account most likely has not been given access" >&2
            echo "to the pro edition by DataSQRL. Ask DataSQRL to grant it, or set DATASQRL_AGENT_EDITION=os" >&2
            echo "to run the open-source edition." >&2
        elif [ "$GHCR_LOGIN_SOURCE" = "stored" ]; then
            echo "" >&2
            echo "ghcr.io refused the pull for $GHCR_LOGIN_USER, the account of the login that Docker stored." >&2
            echo "The stored login can be expired, or DataSQRL has not given this account access to the pro" >&2
            echo "edition. Log in again with a token that has the 'read:packages' scope:" >&2
            echo "  docker login ghcr.io" >&2
            echo "If that does not help, ask DataSQRL for access, or set DATASQRL_AGENT_EDITION=os to run the" >&2
            echo "open-source edition." >&2
        fi
        exit 1
    fi
    _digest="$(pulled_digest "$REGISTRY_IMAGE")"
    if [ -z "$_digest" ]; then
        echo "Error: pulled '$REGISTRY_IMAGE' but Docker recorded no digest for it, so its signature cannot be checked." >&2
        docker rmi "$REGISTRY_IMAGE" >/dev/null 2>&1
        exit 1
    fi
    verify_image_signature "${REGISTRY_IMAGE%:*}" "$_digest"
    _signature_check_result=$?
    if [ "$_signature_check_result" = "1" ]; then
        docker rmi "$REGISTRY_IMAGE" >/dev/null 2>&1
        exit 1
    fi
    if [ "$_signature_check_result" != "0" ]; then
        echo "The pulled image stays on this machine, so the next try needs no new download." >&2
        echo "The launcher runs it only after a signature check passes." >&2
        exit 1
    fi
    if ! docker tag "$REGISTRY_IMAGE" "$LOCAL_IMAGE"; then
        echo "Error: pulled '$REGISTRY_IMAGE' but could not tag it as '$LOCAL_IMAGE'." >&2
        exit 1
    fi
    CHECKED_IMAGE_ID="$(docker image inspect -f '{{.Id}}' "$LOCAL_IMAGE" 2>/dev/null)"
    record_verified_image "$CHECKED_IMAGE_ID"
    # The common tag follows pro whenever pro is local, so pulling os never takes it from pro.
    if [ "$RUN_EDITION" = "pro" ] || ! docker image inspect "$PRO_LOCAL_IMAGE" >/dev/null 2>&1; then
        docker tag "$LOCAL_IMAGE" "$COMMON_IMAGE" >/dev/null 2>&1
    fi
    echo "Pulled $REGISTRY_IMAGE as $LOCAL_IMAGE · $(image_summary "$LOCAL_IMAGE")" >&2
}

# Sets IMAGE_NAME, the name that messages show, and RUN_IMAGE, what `docker run` gets. RUN_IMAGE
# is the ID of an image whose signature this machine verified, so the image cannot change between
# the check and the run. With $1 = pull, a missing or unchecked image is pulled and checked.
# Without it, nothing is pulled: the function names --pull-image and returns 1.
select_checked_image() {
    local _id
    if [ -n "${DATASQRL_AGENT_IMAGE:-}" ]; then
        # A custom image could point anywhere, so guessing where to fetch it from would be wrong.
        IMAGE_NAME="$DATASQRL_AGENT_IMAGE"
        RUN_IMAGE="$DATASQRL_AGENT_IMAGE"
        if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
            echo "Error: image '$IMAGE_NAME' (from DATASQRL_AGENT_IMAGE) is not present locally." >&2
            echo "Build it, pull it, or unset DATASQRL_AGENT_IMAGE to use the published image." >&2
            return 1
        fi
        echo "Warning: DATASQRL_AGENT_IMAGE is set, so '$IMAGE_NAME' runs without a signature check." >&2
        return 0
    fi
    resolve_edition
    IMAGE_NAME="$LOCAL_IMAGE"
    if docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1; then
        _id="$(docker image inspect -f '{{.Id}}' "$LOCAL_IMAGE" 2>/dev/null)"
        if is_verified_image "$_id"; then
            RUN_IMAGE="$_id"
            return 0
        fi
        if [ "${1:-}" != "pull" ]; then
            echo "Error: $LOCAL_IMAGE has no checked signature on this machine. Get a signed image first:" >&2
            echo "  datasqrl-agent.sh --pull-image" >&2
            return 1
        fi
        echo "Image '$LOCAL_IMAGE' has no checked signature on this machine, so the launcher pulls a signed one." >&2
    else
        if [ "${1:-}" != "pull" ]; then
            echo "Error: $LOCAL_IMAGE ($RUN_EDITION edition) is not here yet. Get it first:" >&2
            echo "  datasqrl-agent.sh --pull-image" >&2
            return 1
        fi
        echo "Image '$LOCAL_IMAGE' not found." >&2
    fi
    ensure_image
    if [ -z "$CHECKED_IMAGE_ID" ]; then
        echo "Error: Docker reported no ID for '$LOCAL_IMAGE' after the check." >&2
        return 1
    fi
    RUN_IMAGE="$CHECKED_IMAGE_ID"
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

# --image-exists: one line on stdout, exit 0 when the selected image is local and checked, 1 when
# it is missing or has no checked signature. A DATASQRL_AGENT_IMAGE image is never checked, so it
# only has to be local. It never pulls, so a caller can decide what to do next.
do_image_exists() {
    if [ -n "${DATASQRL_AGENT_IMAGE:-}" ]; then
        _img="$DATASQRL_AGENT_IMAGE"; _what="$DATASQRL_AGENT_IMAGE"
    else
        resolve_edition
        _img="$LOCAL_IMAGE"; _what="$LOCAL_IMAGE ($RUN_EDITION edition)"
    fi
    if docker image inspect "$_img" >/dev/null 2>&1; then
        if [ -z "${DATASQRL_AGENT_IMAGE:-}" ] \
           && ! is_verified_image "$(docker image inspect -f '{{.Id}}' "$_img" 2>/dev/null)"; then
            printf '%s has no checked signature · run: datasqrl-agent.sh --pull-image\n' "$_what"
            return 1
        fi
        printf '%s is present · %s\n' "$_img" "$(image_summary "$_img")"
        return 0
    fi
    printf '%s is missing · run: datasqrl-agent.sh --pull-image\n' "$_what"
    return 1
}

# --- Model provider settings -------------------------------------------------------------------
# Sets PROVIDER_ENV_ARGS to the `-e NAME` arguments that forward provider settings into a container.
provider_env_args() {
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
      # Anthropic and Anthropic-compatible endpoints
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
      AZURE_OPENAI_API_VERSION AZURE_OPENAI_DEPLOYMENT_NAME_MAP
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
      DATASQRL_AGENT_MODEL DATASQRL_AGENT_PROVIDER
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

    PROVIDER_ENV_ARGS=()
    for _name in "${PROVIDER_ENV_VARS[@]}"; do
      [ -n "${!_name+set}" ] && PROVIDER_ENV_ARGS+=(-e "$_name")
    done
}

# --- AWS profiles --------------------------------------------------------------------------------
is_sso_profile() {
    aws configure get sso_session --profile "$1" >/dev/null 2>&1 \
        || aws configure get sso_start_url --profile "$1" >/dev/null 2>&1
}

# Prints one profile's non-secret fields from the AWS config file: account, role and region.
aws_profile_fields() {
    local _cfg="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
    [ -f "$_cfg" ] || return 0
    awk -v want="$1" '
        /^[ \t]*\[/ { s = $0; gsub(/^[ \t]*\[(profile[ \t]+)?|\][ \t]*$/, "", s); next }
        s == want && /=/ {
            k = $0; sub(/[ \t]*=.*/, "", k); gsub(/^[ \t]+/, "", k)
            v = $0; sub(/^[^=]*=[ \t]*/, "", v)
            if (k == "sso_account_id") a = "account " v
            if (k == "sso_role_name")  r = "role " v
            if (k == "region")         g = "region " v
        }
        END { out = a; if (r != "") out = out (out != "" ? " · " : "") r
              if (g != "") out = out (out != "" ? " · " : "") g; print out }
    ' "$_cfg"
}

# The AWS lines of --check-config. AWS is only checked when the run needs it: a Bedrock provider or
# an opted-in log upload, the same rule a run applies. Returns 1 when no usable AWS credential is
# found. AWS_PROFILE is then unset, so the image reports it missing too, as a run would see it.
check_aws() {
    if [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
        echo "AWS                access keys from your shell (they take precedence over AWS_PROFILE)"
        unset AWS_PROFILE
        return 0
    fi
    if [ -n "${AWS_BEARER_TOKEN_BEDROCK:-}" ]; then
        echo "AWS                a Bedrock API key from your shell (AWS_BEARER_TOKEN_BEDROCK)"
        return 0
    fi
    if ! command -v aws >/dev/null 2>&1; then
        echo "AWS                a profile needs the AWS CLI v2, which is not installed"
        echo "  → install it: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        unset AWS_PROFILE
        return 1
    fi
    if [ -z "${AWS_PROFILE:-}" ]; then
        local _p _f _any=0
        echo "AWS                no AWS_PROFILE is set. Profiles on this machine:"
        while IFS= read -r _p; do
            [ -n "$_p" ] || continue
            _any=1
            _f="$(aws_profile_fields "$_p")"
            printf '  %-28s %s\n' "$_p" "${_f:-no account, role or region recorded}"
        done < <(aws configure list-profiles 2>/dev/null)
        if [ "$_any" = "1" ]; then
            echo "  → ask the user which profile is for DataSQRL, then run with AWS_PROFILE=<name>"
        else
            echo "  (none)"
            echo "  → ask the user to set up a profile (aws configure sso), or to set access keys"
        fi
        return 1
    fi
    local _account _region
    if _account="$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text 2>/dev/null)" \
       && [ -n "$_account" ]; then
        _region="${AWS_REGION:-$(aws configure get region --profile "$AWS_PROFILE" 2>/dev/null)}"
        echo "AWS                profile $AWS_PROFILE · account $_account · region ${_region:-us-east-1}"
        return 0
    fi
    if is_sso_profile "$AWS_PROFILE"; then
        echo "AWS                profile $AWS_PROFILE: the SSO login is missing or expired"
        echo "  → ask the user to run: aws sso login --profile $AWS_PROFILE"
    else
        echo "AWS                profile $AWS_PROFILE gives no usable credential"
        echo "  → see why with: aws sts get-caller-identity --profile $AWS_PROFILE"
    fi
    unset AWS_PROFILE
    return 1
}

# --check-config: the harness, provider and model a run would use and whether its credentials are
# ready. The image answers for its variables; the AWS check runs here, because the profile and its
# login live on this machine and never enter the container. Exits 0 when ready and 1 when not.
do_check_config() {
    local _provider="${DATASQRL_AGENT_PROVIDER:-}" _take=0 _a _out _rc _aws_ok=1 _aws_lines=""
    select_checked_image || return 1
    for _a in "$@"; do
        if [ "$_take" = "1" ]; then _provider="$_a"; _take=0; continue; fi
        case "$_a" in
            --provider)   _take=1 ;;
            --provider=*) _provider="${_a#--provider=}" ;;
        esac
    done
    case "$_provider" in
        amazon-bedrock|bedrock) _aws_lines="$(check_aws)" || _aws_ok=0 ;;
        *)
            if [ "${DATASQRL_TELEMETRY:-}" = "1" ]; then
                _aws_lines="$(check_aws)" || _aws_ok=0
            fi
            ;;
    esac
    # check_aws ran in a subshell, so its unset has to be repeated here before forwarding.
    [ "$_aws_ok" = "0" ] && unset AWS_PROFILE
    case "$_provider" in amazon-bedrock|bedrock) ;; *) [ "${DATASQRL_TELEMETRY:-}" = "1" ] || unset AWS_PROFILE ;; esac

    provider_env_args
    _out="$(docker run --rm "${PROVIDER_ENV_ARGS[@]}" "$RUN_IMAGE" --check-config "$@")"
    _rc=$?
    printf 'Image              %s · %s\n' "$IMAGE_NAME" "$(image_summary "$IMAGE_NAME")"
    if ! printf '%s\n' "$_out" | grep -q '^Status '; then
        [ -n "$_out" ] && printf '%s\n' "$_out"
        return "$_rc"
    fi
    printf '%s\n' "$_out" | grep -v '^Status '
    [ -n "$_aws_lines" ] && printf '%s\n' "$_aws_lines"
    if [ "$_rc" = "0" ] && [ "$_aws_ok" = "1" ]; then
        echo "Status             READY"
        return 0
    fi
    echo "Status             NOT READY"
    return 1
}

# --show-options [ID]: the harnesses, providers and defaults the image offers, answered by the image
# itself. The launcher names no harness or provider, so it says nothing the image does not.
# Provider settings reach the container by name, as for a run, so the image can say which are set.
# It never pulls: a 3GB download is not a side effect of a question.
do_show_options() {
    select_checked_image || return 1
    provider_env_args
    printf 'Image              %s · %s\n' "$IMAGE_NAME" "$(image_summary "$IMAGE_NAME")"
    docker run --rm "${PROVIDER_ENV_ARGS[@]}" "$RUN_IMAGE" --show-options ${OPTIONS_ID:+"$OPTIONS_ID"} "$@"
}

# --- Argument partitioning ---------------------------------------------------------------------
# Lifetime flags are consumed here and MUST NOT reach the Python CLI, which does not know them.
# Everything else is left in place for the requirements/forwarding split below.
DETACH=0
ACTION="run"
TAIL_N=0          # --status N: print the last N trail lines before the status line
OPTIONS_ID=""     # --show-options ID: one provider instead of the list
REST_ARGS=()
_after_status=0
_after_options=0
for _arg in "$@"; do
    if [ "$_after_status" = "1" ]; then
        _after_status=0
        case "$_arg" in
            *[!0-9]*|'') ;;                    # not a number: plain --status
            *) TAIL_N="$_arg"; continue ;;
        esac
    fi
    if [ "$_after_options" = "1" ]; then
        _after_options=0
        case "$_arg" in
            -*) ;;                             # a flag: plain --show-options
            *)  OPTIONS_ID="$_arg"; continue ;;
        esac
    fi
    case "$_arg" in
        --detach) DETACH=1 ;;
        --status) ACTION="status"; _after_status=1 ;;
        --stop)   ACTION="stop" ;;
        --wait)   ACTION="wait" ;;
        --pull-image)   ACTION="pull-image" ;;
        --image-exists) ACTION="image-exists" ;;
        --show-options) ACTION="show-options"; _after_options=1 ;;
        --check-config) ACTION="check-config" ;;
        *)        REST_ARGS+=("$_arg") ;;
    esac
done
set -- "${REST_ARGS[@]}"

# The image actions run before the repository check: they touch no project, so they work from
# any directory, including before a project exists.
case "$ACTION" in
    check-config)
        # It takes the choices a run takes, and answers for them.
        _take_value=0
        for _a in "$@"; do
            if [ "$_take_value" = "1" ]; then _take_value=0; continue; fi
            case "$_a" in
                --agent|--harness|--provider|--model) _take_value=1 ;;
                --agent=*|--harness=*|--provider=*|--model=*) ;;
                *)
                    echo "Error: --check-config takes --harness, --provider and --model, not '$_a'." >&2
                    exit 1
                    ;;
            esac
        done
        if [ "$DETACH" = "1" ]; then
            echo "Error: --check-config starts no run, so --detach does not apply." >&2
            exit 1
        fi
        require_docker
        do_check_config "$@"
        exit $?
        ;;
    show-options)
        # The menu differs per harness, so it takes --harness. --provider names the provider to
        # show, the same as an id after the flag.
        _take_value=0
        for _a in "$@"; do
            if [ "$_take_value" = "1" ]; then _take_value=0; continue; fi
            case "$_a" in
                --agent|--harness|--provider) _take_value=1 ;;
                --agent=*|--harness=*|--provider=*) ;;
                *)
                    echo "Error: --show-options takes a provider id, --provider and --harness, not '$_a'." >&2
                    exit 1
                    ;;
            esac
        done
        if [ "$DETACH" = "1" ]; then
            echo "Error: --show-options starts no run, so --detach does not apply." >&2
            exit 1
        fi
        require_docker
        do_show_options "$@"
        exit $?
        ;;
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
# token that starts with '-' is a flag (e.g. `datasqrl-agent.sh --mode implementation`, which
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
elif [ "${DATASQRL_AGENT_ALLOW_NO_GIT:-}" = "1" ]; then
    # Escape hatch for CI/automation: treat the current directory as a standalone project.
    MOUNT_DIR="$(pwd -P)"
    PROJECT_REL="."
    echo "Warning: not inside a git repository; DATASQRL_AGENT_ALLOW_NO_GIT=1 set, continuing with the current directory only." >&2
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
    echo "For CI/automation only, set DATASQRL_AGENT_ALLOW_NO_GIT=1 to bypass this check." >&2
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
RUN_NAME="datasqrl-agent-${PROJECT_SLUG}-$(_short_hash "$PROJECT_ABS")"

# The container writes both of these into the project through the bind mount, so they are live on
# the host while the run is going. They — not `docker logs` — are the status channel, which is what
# makes --rm safe and lets --status re-attach from a different shell or a later session.
#
# PROGRESS_PATH is the human-readable trail the container renders from its log: one record per
# line, `+HH:MM:SS  KIND   text`, continuation lines indented. Truncated when a run starts and left
# in place afterwards, so the last run's trail can be revisited until the next run overwrites it.
PROGRESS_PATH="$PROJECT_ABS/.datasqrl/datasqrl-agent-progress.txt"
RESULTS_PATH="$PROJECT_ABS/.datasqrl_agent_results.json"

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

# Read one field of the newest run out of the pretty-printed results file. The newest run is
# first, and the line that is exactly `    }` closes it. Reading stops there, so a field that the
# newest run lacks is never taken from an older run.
result_field() {
    [ -f "$RESULTS_PATH" ] || return 0
    awk -v key="\"$1\"" '
        /^    }/ { exit }
        index($0, key) { sub(/.*: */, ""); gsub(/[",]/, ""); gsub(/^ +| +$/, ""); print; exit }
    ' "$RESULTS_PATH" 2>/dev/null
}

# The note after the score, as the agent prints it: when the code checks or the LLM judges are
# partial or failed, name each of the two that ran, with its status. A run from an older image has
# neither field and gets no note.
status_note() {
    case "$1 $2" in *partial*|*failed*) ;; *) return 0 ;; esac
    _planes=""
    case "$1" in ''|null) ;; *) _planes="code checks: $1" ;; esac
    case "$2" in ''|null) ;; *) _planes="${_planes:+$_planes, }LLM judges: $2" ;; esac
    printf '[%s]' "$_planes"
}

result_issues() {
    _score="$(result_field issue_score)"
    case "$_score" in ''|null) return 0 ;; esac
    awk '
        /"issue_count": \{/ { inside = 1; next }
        inside && /}/ { exit }
        inside {
            gsub(/[",]/, ""); split($0, kv, ":"); key = kv[1]; val = kv[2]
            gsub(/ /, "", key); gsub(/ /, "", val)
            if (key == "total") total = val
            else counts = counts (counts == "" ? "" : ", ") val " " key
        }
        END { printf "%s issue(s) (%s)", total, counts }
    ' "$RESULTS_PATH"
    printf ' · score %s' "$_score"
    _note="$(status_note "$(result_field code_check_status)" "$(result_field llm_judge_status)")"
    [ -n "$_note" ] && printf ' %s' "$_note"
    return 0
}

result_summary() {
    [ -f "$RESULTS_PATH" ] || return 0
    _ok="$(result_field success)"
    if [ "$_ok" = "true" ]; then _ok="success"; else _ok="failed"; fi
    printf '%s · %s · %s · %s refinement(s)' \
        "$_ok" "$(result_field mode)" "$(result_field scenario)" "$(result_field refinements)"
    _issues="$(result_issues)"
    [ -n "$_issues" ] && printf ' · %s' "$_issues"
    return 0
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
        echo "  ./datasqrl-agent.sh \"Add a metrics endpoint\"          # plan from text"
        echo "  ./datasqrl-agent.sh requirements.md                    # plan from file"
        echo "  ./datasqrl-agent.sh --mode implementation              # implement from latest ADR"
        echo "  ./datasqrl-agent.sh my_adr.md --mode implementation    # implement from specific ADR"
        echo "  ./datasqrl-agent.sh \"widen the window\" --mode patch    # small change, no planning"
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
    echo "  ./datasqrl-agent.sh \"widen the aggregation window to 2 hours\" --mode patch" >&2
    echo "  ./datasqrl-agent.sh change-notes.md --mode patch" >&2
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
# an empty log. The same step checks the image's signature, and the run uses the checked image ID.
select_checked_image pull || exit 1
IMAGE="$RUN_IMAGE"

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
    echo "  ./datasqrl-agent.sh --status" >&2
    echo "  ./datasqrl-agent.sh --stop" >&2
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

# The coding agent's provider: the --provider flag, else DATASQRL_AGENT_PROVIDER, as in the CLI.
RUN_PROVIDER="${DATASQRL_AGENT_PROVIDER:-}"
_take_next=0
for _a in "${FORWARD_ARGS[@]}"; do
    if [ "$_take_next" = "1" ]; then RUN_PROVIDER="$_a"; break; fi
    case "$_a" in
        --provider)   _take_next=1 ;;
        --provider=*) RUN_PROVIDER="${_a#--provider=}"; break ;;
    esac
done

# The coding agent's model: the --model flag, else DATASQRL_AGENT_MODEL, as in the CLI.
RUN_MODEL="${DATASQRL_AGENT_MODEL:-}"
_take_next=0
for _a in "${FORWARD_ARGS[@]}"; do
    if [ "$_take_next" = "1" ]; then RUN_MODEL="$_a"; break; fi
    case "$_a" in
        --model)   _take_next=1 ;;
        --model=*) RUN_MODEL="${_a#--model=}"; break ;;
    esac
done

# A Claude login is needed only when the agent, and so the judges, run on Anthropic. Without
# --provider, a provider/ prefix on the model names the provider, as Pi reads it; a bare model
# is Anthropic's.
_model_provider=""
[[ "$RUN_MODEL" == */* ]] && _model_provider="${RUN_MODEL%%/*}"
case "${RUN_PROVIDER:-${_model_provider:-anthropic}}" in
    anthropic) CLAUDE_LOGIN_NEEDED=1 ;;
    *)         CLAUDE_LOGIN_NEEDED=0 ;;
esac

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
        TEMP_CREDENTIALS="${TMPDIR:-/tmp}/datasqrl-agent-creds-${RUN_NAME}.json"
        rm -f "$TEMP_CREDENTIALS"
        (umask 077; printf '%s' "$1" > "$TEMP_CREDENTIALS")
    else
        TEMP_CREDENTIALS="$(mktemp)"
        printf '%s' "$1" > "$TEMP_CREDENTIALS"
        PATHS_TO_REMOVE_ON_EXIT+=("$TEMP_CREDENTIALS")
    fi
    CREDENTIALS_FILE="$TEMP_CREDENTIALS"
}

if [ "$CLAUDE_LOGIN_NEEDED" = "1" ] && [ -z "$ANTHROPIC_API_KEY" ]; then
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
    _mac=$(ifconfig en0 2>/dev/null | awk '/ether/{print $2; exit}')
    [ -z "$_mac" ] && _mac=$(ifconfig 2>/dev/null | awk '/ether/{print $2; exit}')
else
    _mac=$(ip link show 2>/dev/null | awk '/link\/ether/{print $2; exit}')
    if [ -z "$_mac" ]; then
        # The first interface with a real address; /sys/class/net also holds files such as
        # bonding_masters and tunnels whose address is all zeros.
        for _if in /sys/class/net/*; do
            [ "${_if##*/}" = lo ] && continue
            _mac=$(cat "$_if/address" 2>/dev/null)
            case "$_mac" in ""|00:00:00:00:00:00) _mac="" ;; *) break ;; esac
        done
    fi
fi
HOST_MAC_ID="$_mac"
unset _mac _if

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

# Only an Anthropic run gets the Claude login; another provider's container never sees it.
if [ "$CLAUDE_LOGIN_NEEDED" = "1" ] && [ -f "$CREDENTIALS_FILE" ]; then
  DOCKER_ARGS+=(-v "$CREDENTIALS_FILE:/root/.claude/.credentials.json:ro")
fi

# --- Model provider settings -------------------------------------------------------------------
# Forwarded by name; see provider_env_args.
provider_env_args
DOCKER_ARGS+=("${PROVIDER_ENV_ARGS[@]}")

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

# CLI arguments that datasqrl-agent.sh owns (container paths for the reconstructed layout).
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
