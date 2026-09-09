#!/bin/bash
#
# DataSQRL Cloud API client for the `deploy` skill.
#
# Usage: ./datasqrl-cloud.sh <subcommand> [options...]
#
# The subcommand list below is the permission boundary. Every DataSQRL Cloud write this
# script can perform is one of `deploy` or `promote`; terminate, stop, start, resize,
# upgrade, and project/member/secret management have no subcommand and so cannot be
# reached, whatever a prompt asks for. Adding one is a deliberate edit here, not a
# decision an agent makes at run time.
#
#   Auth
#     login                     Device authorization flow. Prints a code and a URL for a
#                               human to approve in a browser, then polls for the token.
#     whoami                    Show the cached token's subject, expiry and org ids.
#     logout                    Delete the cached token.
#
#   Read
#     orgs                      Org ids from the token (org_* only), with names.
#     projects                  Projects in an org.
#     project-id [--name NAME]  Resolve a project name to its id; with no --name, identify the
#                               project from this repository's remote and path.
#     deployments               Deployments in a project (or across the org).
#     deployment <id>           One deployment.
#     status <id>               Current status and per-service statuses.
#     details <id>              Per-stage timeline. The useful view when a compile fails.
#     logs                      Deployment logs.
#     find-commit --commit SHA  Live deployments already on that commit.
#     wait <id>                 Poll status once a minute for 15 minutes.
#
#   Write
#     deploy --commit SHA       Create a deployment from a commit. Prints its Web UI URL. The
#                               branch label is derived from the commit unless --branch says so.
#     promote <id>              Make a deployment the project's main one.
#
# Common options: --org ID, --project ID, --base-url URL, --json, -h/--help.
# Requires the commit to be on a remote branch; `deploy` warns when none contains it.
#
# Requires curl and jq.

DEFAULT_BASE_URL="https://dev.datasqrl.com"
BASE_URL="${DATASQRL_BASE_URL:-$DEFAULT_BASE_URL}"

# Auth0 caps the device-code grant at 900s; the response carries the authoritative values
# and these are only the fallback when it omits them.
DEVICE_POLL_INTERVAL=5
DEVICE_POLL_EXPIRY=900

# A deployment compiles and starts a Flink job, so minutes are normal. Timing out is not a
# failure — `wait` hands back the deployment id and the user re-checks.
WAIT_INTERVAL=60
WAIT_MAX_SECONDS=900

# Refresh this far ahead of expiry so a slow request cannot straddle the boundary.
REFRESH_SKEW_SECONDS=120

ORG_IDS_CLAIM="https://datasqrl.com/data_group_ids"

die() {
    echo "Error: $1" >&2
    exit 1
}

# `bash datasqrl-cloud.sh` searches PATH when the name has no slash, leaving $0 as the bare
# name — which nothing can open. usage() reads this file, so resolve it back to a real path.
SELF="${BASH_SOURCE[0]}"
case "$SELF" in
    */*) ;;
    *) SELF=$(command -v "$SELF" 2>/dev/null || printf '%s' "$SELF") ;;
esac

# --- Preflight ---------------------------------------------------------------------------------

for tool in curl jq; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed or not on PATH.
Install it and re-run:
  macOS:          brew install $tool
  Debian/Ubuntu:  sudo apt-get install -y $tool
  Windows:        winget install $tool   (in Git Bash; or scoop/choco)"
done

# --- Argument parsing --------------------------------------------------------------------------

SUBCOMMAND="$1"
shift 2>/dev/null
case "$SUBCOMMAND" in -h|--help) SUBCOMMAND="help" ;; esac

ARG_ORG=""
ARG_PROJECT="${DATASQRL_PROJECT_ID:-}"
ARG_COMMIT=""
ARG_BRANCH=""
ARG_NAME=""
ARG_DEPLOYMENT=""
ARG_LIMIT=""
ARG_JSON=0
ARG_FORCE=0
EXTRA_PACKAGE_JSON=()
POSITIONAL=()

# `shift 2` fails when only the option itself is left, which leaves $# unchanged and spins this
# loop forever. Every value-taking option checks first.
require_value() {
    [ "$#" -ge 2 ] || die "option '$1' needs a value."
}

while [ $# -gt 0 ]; do
    case "$1" in
        --org) require_value "$@"; ARG_ORG="$2"; shift 2 ;;
        --project) require_value "$@"; ARG_PROJECT="$2"; shift 2 ;;
        --commit) require_value "$@"; ARG_COMMIT="$2"; shift 2 ;;
        --branch) require_value "$@"; ARG_BRANCH="$2"; shift 2 ;;
        --name) require_value "$@"; ARG_NAME="$2"; shift 2 ;;
        --deployment) require_value "$@"; ARG_DEPLOYMENT="$2"; shift 2 ;;
        --limit) require_value "$@"; ARG_LIMIT="$2"; shift 2 ;;
        --base-url) require_value "$@"; BASE_URL="$2"; shift 2 ;;
        --json) ARG_JSON=1; shift ;;
        --force) ARG_FORCE=1; shift ;;
        --extra-package-json)
            shift
            while [ $# -gt 0 ] && [ "${1:0:2}" != "--" ]; do
                EXTRA_PACKAGE_JSON+=("$1")
                shift
            done
            ;;
        -h|--help) SUBCOMMAND="help"; shift ;;
        --*) die "unknown option '$1'. Run --help for the subcommand list." ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

BASE_URL="${BASE_URL%/}"
API="$BASE_URL/api/v1"

# Column-aligns tab-separated stdin. `column -t` would do this, but it comes from util-linux
# and is absent on Git for Windows; awk is already required by usage() and present everywhere.
table() {
    awk -F'\t' '{
        for (i = 1; i <= NF; i++) {
            if (length($i) > w[i]) w[i] = length($i)
            c[NR, i] = $i
        }
        n[NR] = NF
    }
    END {
        for (r = 1; r <= NR; r++) {
            line = ""
            for (i = 1; i <= n[r]; i++) line = line sprintf("%-*s  ", w[i], c[r, i])
            sub(/ +$/, "", line)
            print line
        }
    }'
}

# --- Token cache -------------------------------------------------------------------------------

CACHE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/datasqrl"
CACHE_FILE="$CACHE_DIR/credentials.json"

# Tokens are keyed by host so a token minted against a preview deployment is never sent to
# production. The 0600 below is a no-op on NTFS under Git Bash, so on Windows the cache is
# only as private as the user's profile directory.
cache_key() {
    local host="${BASE_URL#*://}"
    printf '%s' "${host%%/*}"
}

read_cached() {
    [ -f "$CACHE_FILE" ] || return 1
    jq -er --arg k "$(cache_key)" --arg f "$1" '.[$k][$f] // empty' "$CACHE_FILE" 2>/dev/null
}

write_cached() {
    local access="$1" refresh="$2" expires_in="$3"
    local expires_at=$(( $(date +%s) + expires_in ))
    mkdir -p "$CACHE_DIR" || die "cannot create $CACHE_DIR"

    local existing='{}'
    [ -f "$CACHE_FILE" ] && existing=$(cat "$CACHE_FILE")

    local tmp
    tmp=$(mktemp "$CACHE_DIR/.credentials.XXXXXX") || die "cannot write to $CACHE_DIR"
    chmod 600 "$tmp"
    printf '%s' "$existing" | jq \
        --arg k "$(cache_key)" \
        --arg a "$access" \
        --arg r "$refresh" \
        --argjson e "$expires_at" \
        '.[$k] = {access_token: $a, refresh_token: $r, expires_at: $e}' >"$tmp" \
        || { rm -f "$tmp"; die "failed to write the token cache"; }
    mv "$tmp" "$CACHE_FILE"
    chmod 600 "$CACHE_FILE"
}

decode_jwt_payload() {
    local payload="${1#*.}"
    payload="${payload%%.*}"
    # base64url -> base64: restore the padding jq needs, then swap the alphabet.
    case $(( ${#payload} % 4 )) in
        2) payload="$payload==" ;;
        3) payload="$payload=" ;;
    esac
    printf '%s' "$payload" | tr '_-' '/+' | base64 -d 2>/dev/null
}

# --- HTTP --------------------------------------------------------------------------------------

# Sets HTTP_STATUS and HTTP_BODY rather than returning them, so a body containing a newline
# survives and callers can branch on the status without re-parsing.
HTTP_STATUS=""
HTTP_BODY=""
request() {
    local method="$1" url="$2" body="${3:-}"
    local -a curl_args=(-sS -X "$method" -w '\n%{http_code}' -H 'Accept: application/json')
    [ -n "$ACCESS_TOKEN" ] && curl_args+=(-H "Authorization: Bearer $ACCESS_TOKEN")
    if [ -n "$body" ]; then
        curl_args+=(-H 'Content-Type: application/json' --data-binary "$body")
    fi

    local response
    response=$(curl "${curl_args[@]}" "$url") || die "request to $url failed"
    HTTP_STATUS="${response##*$'\n'}"
    HTTP_BODY="${response%$'\n'*}"
}

api_error_message() {
    printf '%s' "$HTTP_BODY" | jq -r '.message // .error_description // .error // empty' 2>/dev/null
}

# Fails the run on any non-2xx. 401 and 403 get their own text because they are the two a
# user can act on themselves.
require_ok() {
    case "$HTTP_STATUS" in
        2*) return 0 ;;
        401) die "not authenticated ($(api_error_message)). Run: $0 login" ;;
        403) die "$(api_error_message)" ;;
        *) die "HTTP $HTTP_STATUS from the DataSQRL API: $(api_error_message)
$HTTP_BODY" ;;
    esac
}

# --- Authentication ----------------------------------------------------------------------------

ACCESS_TOKEN=""

do_login() {
    ACCESS_TOKEN=""
    request POST "$BASE_URL/auth/device/code"
    require_ok

    local device_code user_code verify_url interval expires_in
    device_code=$(printf '%s' "$HTTP_BODY" | jq -r '.device_code')
    user_code=$(printf '%s' "$HTTP_BODY" | jq -r '.user_code')
    verify_url=$(printf '%s' "$HTTP_BODY" | jq -r '.verification_uri_complete')
    interval=$(printf '%s' "$HTTP_BODY" | jq -r ".interval // $DEVICE_POLL_INTERVAL")
    expires_in=$(printf '%s' "$HTTP_BODY" | jq -r ".expires_in // $DEVICE_POLL_EXPIRY")

    [ -n "$device_code" ] && [ "$device_code" != "null" ] || die "no device_code in the response"

    cat <<EOF
Sign in to DataSQRL Cloud ($BASE_URL)

  1. Open: $verify_url
  2. Confirm this code is shown: $user_code
  3. Approve the request.

Waiting for approval (expires in $(( expires_in / 60 )) minutes)...
EOF

    local deadline=$(( $(date +%s) + expires_in ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        sleep "$interval"
        request GET "$BASE_URL/auth/device/token?device_code=$device_code"

        if [ "${HTTP_STATUS:0:1}" = "2" ]; then
            write_cached \
                "$(printf '%s' "$HTTP_BODY" | jq -r '.access_token')" \
                "$(printf '%s' "$HTTP_BODY" | jq -r '.refresh_token')" \
                "$(printf '%s' "$HTTP_BODY" | jq -r '.expires_in')"
            echo "Signed in."
            do_whoami
            return 0
        fi

        case "$(printf '%s' "$HTTP_BODY" | jq -r '.data.error // empty')" in
            authorization_pending) ;;
            # Auth0 asks us to back off; obeying it avoids being cut off entirely.
            slow_down) interval=$(( interval + 5 )) ;;
            access_denied) die "the request was denied in the browser." ;;
            expired_token) die "the code expired before it was approved. Run login again." ;;
            *) die "device authorization failed: $(api_error_message)" ;;
        esac
    done
    die "timed out waiting for browser approval. Run login again."
}

# Populates ACCESS_TOKEN, refreshing when it is close to expiry. Every read and write goes
# through this.
load_token() {
    local expires_at
    ACCESS_TOKEN=$(read_cached access_token) \
        || die "not authenticated for $(cache_key). Run: $0 login"
    expires_at=$(read_cached expires_at || echo 0)

    if [ "$(( expires_at - REFRESH_SKEW_SECONDS ))" -le "$(date +%s)" ]; then
        local refresh_token
        refresh_token=$(read_cached refresh_token) \
            || die "the access token expired and no refresh token is cached. Run: $0 login"

        # Cleared so the refresh call is unauthenticated; an expired bearer would 401 it.
        ACCESS_TOKEN=""
        request POST "$BASE_URL/auth/device/token/refresh" \
            "$(jq -nc --arg t "$refresh_token" '{refresh_token: $t}')"
        [ "${HTTP_STATUS:0:1}" = "2" ] \
            || die "could not refresh the access token ($(api_error_message)). Run: $0 login"

        # Auth0 rotates the refresh token, so both values must be stored or the next
        # refresh fails with an already-used token.
        write_cached \
            "$(printf '%s' "$HTTP_BODY" | jq -r '.access_token')" \
            "$(printf '%s' "$HTTP_BODY" | jq -r '.refresh_token')" \
            "$(printf '%s' "$HTTP_BODY" | jq -r '.expires_in')"
        ACCESS_TOKEN=$(read_cached access_token)
    fi
}

do_whoami() {
    load_token
    local payload
    payload=$(decode_jwt_payload "$ACCESS_TOKEN") || die "the cached token is not a readable JWT"

    # Filtered the same way as `orgs`, so the two never disagree about how many there are.
    if [ "$ARG_JSON" = 1 ]; then
        printf '%s' "$payload" | jq --arg c "$ORG_IDS_CLAIM" \
            '{subject: .sub, expires_at: .exp,
              org_ids: [(.[$c] // [])[] | select(startswith("org_"))]}'
        return
    fi
    printf '%s' "$payload" | jq -r --arg c "$ORG_IDS_CLAIM" '
        "Signed in as \(.sub)",
        "Token expires:  \(.exp | todate)",
        "Organizations:  \([(.[$c] // [])[] | select(startswith("org_"))] | join(", "))"'
}

# --- Org and project resolution ----------------------------------------------------------------

# Auth0 organization ids are `org_`-prefixed; the claim is passed to Auth0 verbatim by the
# backend. Anything else in there is not an org and would 403 every request made with it.
token_org_ids() {
    decode_jwt_payload "$ACCESS_TOKEN" \
        | jq -r --arg c "$ORG_IDS_CLAIM" '(.[$c] // [])[] | select(startswith("org_"))'
}

# Every helper that can fail sets a global rather than echoing its result: `die` inside a
# `$(...)` would exit only the subshell, and the caller would carry on with an empty value.
ORG_ID=""
DEPLOYMENT_ID=""
FOUND_DEPLOYMENTS=""

# There is no endpoint that lists the caller's orgs, so the token claim is the only source.
resolve_org() {
    if [ -n "$ARG_ORG" ]; then
        ORG_ID="$ARG_ORG"
        return
    fi
    local ids count
    ids=$(token_org_ids)
    count=$(printf '%s\n' "$ids" | grep -c . )
    case "$count" in
        0) die "the signed-in token grants no organizations. Ask a team owner to add you, then
run '$0 login' again to pick up the new membership." ;;
        1) ORG_ID="$ids" ;;
        *) die "this account belongs to $count organizations. Pass --org ID.
Run '$0 orgs' to list them." ;;
    esac
}

require_project() {
    [ -n "$ARG_PROJECT" ] || die "no project. Pass --project ID, or resolve a name with:
  $0 project-id --name '<project name>'"
}

require_deployment() {
    DEPLOYMENT_ID="${POSITIONAL[0]:-$ARG_DEPLOYMENT}"
    [ -n "$DEPLOYMENT_ID" ] || die "pass a deployment id"
}

fetch_projects() {
    # This endpoint takes `organizationId`; every other endpoint takes `orgId`.
    # 1000 is the server's maximum and its default, so one call already returns as much as a
    # single page can.
    request GET "$API/projects?organizationId=$1&limit=${2:-1000}"
    require_ok
}

# --- Web UI links ------------------------------------------------------------------------------

DEPLOYMENT_URL=""
ORG_NAME=""

# A deployment id is not something a user can act on; the page for it is. The route is
# /<orgName>/<projectId>/<deploymentId>, and orgName is the org's slug — only the projects
# endpoint returns it, and only its `full` shape, so ask for that explicitly rather than
# relying on the default. Best-effort: a failure here must not fail a deployment that worked,
# so DEPLOYMENT_URL is simply left empty and the caller prints the id alone.
resolve_deployment_url() {
    DEPLOYMENT_URL=""
    # The URL needs the project id, which not every subcommand is given.
    [ -n "$ARG_PROJECT" ] || return 0
    if [ -z "$ORG_NAME" ]; then
        request GET "$API/projects/$ARG_PROJECT?organizationId=$ORG_ID&type=full"
        [ "${HTTP_STATUS:0:1}" = "2" ] || return 0
        ORG_NAME=$(printf '%s' "$HTTP_BODY" | jq -r '.orgName // empty' 2>/dev/null)
    fi
    [ -n "$ORG_NAME" ] || return 0
    DEPLOYMENT_URL="$BASE_URL/$ORG_NAME/$ARG_PROJECT/$1"
}

# Prints the page for a deployment, falling back to its id when the URL cannot be built.
report_deployment() {
    resolve_deployment_url "$1"
    if [ -n "$DEPLOYMENT_URL" ]; then
        echo "  View it:       $DEPLOYMENT_URL"
    else
        echo "  Deployment id: $1"
    fi
}

# --- Deployment branch label -------------------------------------------------------------------

BRANCH_LABEL=""

# The deployment's branch is a label; the commit decides what runs. It must therefore name a
# remote branch that actually CONTAINS the commit, which is not the same as the branch checked
# out now: deploying a tag or a sha from elsewhere would otherwise be labelled with whatever
# HEAD happens to be on, and in detached HEAD there is no branch to read at all.
resolve_branch_label() {
    local sha="$1"
    if [ -n "$ARG_BRANCH" ]; then
        BRANCH_LABEL="$ARG_BRANCH"
        return
    fi
    BRANCH_LABEL=""
    git rev-parse --git-dir >/dev/null 2>&1 || return

    local candidates upstream default
    # A remote-tracking ref with no slash (a bare `origin`) is not a branch name; `*/HEAD` is a
    # symbolic alias for another entry in this same list.
    candidates=$(git branch -r --contains "$sha" --format='%(refname:short)' 2>/dev/null \
        | grep '/' | grep -v '/HEAD$')
    if [ -z "$candidates" ]; then
        echo "Warning: no remote branch contains $sha. If GitHub does not have this commit the" >&2
        echo "         deployment will fail — push it, or run 'git fetch' if it was pushed" >&2
        echo "         elsewhere. Continuing without a branch label." >&2
        return
    fi

    upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
    if [ -n "$upstream" ] && printf '%s\n' "$candidates" | grep -qxF "$upstream"; then
        BRANCH_LABEL="${upstream#*/}"
        return
    fi
    default=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
    if [ -n "$default" ] && printf '%s\n' "$candidates" | grep -qxF "$default"; then
        BRANCH_LABEL="${default#*/}"
        return
    fi
    BRANCH_LABEL=$(printf '%s\n' "$candidates" | head -1)
    BRANCH_LABEL="${BRANCH_LABEL#*/}"
}

# --- Subcommands -------------------------------------------------------------------------------

cmd_orgs() {
    load_token
    local out='[]'
    while read -r org_id; do
        [ -n "$org_id" ] || continue
        # No endpoint returns an org's name, but every project carries the name of the org it
        # belongs to — so one project is all this needs. An org with no projects resolves to
        # its bare id, which is a dead end for deploying anyway.
        fetch_projects "$org_id" 1
        out=$(printf '%s' "$out" | jq \
            --arg id "$org_id" \
            --argjson projects "$HTTP_BODY" \
            '. + [{orgId: $id, name: ($projects[0].orgName // null)}]')
    done <<<"$(token_org_ids)"

    if [ "$ARG_JSON" = 1 ]; then
        printf '%s\n' "$out" | jq .
        return
    fi
    printf '%s' "$out" | jq -r '.[] |
        "\(.orgId)\t\(.name // "(no projects — name unavailable)")"' \
        | table
}

cmd_projects() {
    load_token
    resolve_org
    fetch_projects "$ORG_ID"
    if [ "$ARG_JSON" = 1 ]; then
        printf '%s\n' "$HTTP_BODY" | jq .
        return
    fi
    printf '%s' "$HTTP_BODY" | jq -r '.[] | "\(.projectId)\t\(.name)\t\(.label // "")"' \
        | table
}

# owner/repo, from any of git@host:o/r.git, https://host/o/r.git, ssh://git@host/o/r
normalize_repo_url() {
    printf '%s' "$1" | sed -E 's#^[a-z+]+://##; s#^[^@]+@##; s#^[^/:]+[:/]##; s#\.git$##' \
        | tr '[:upper:]' '[:lower:]'
}

# With --name, match on the name. Without it, identify the project from the repository this is
# run in: the API returns each project's `source` (its GitHub URL) and `sourcePath`, which
# together pin one project even when the org has several, and when the repo holds several.
cmd_project_id() {
    load_token
    resolve_org
    fetch_projects "$ORG_ID"

    local matches
    if [ -n "$ARG_NAME" ]; then
        matches=$(printf '%s' "$HTTP_BODY" | jq -r --arg n "$ARG_NAME" '
            [.[] | select(.name == $n)] as $exact
            | (if ($exact | length) > 0 then $exact
               else [.[] | select(.name | ascii_downcase | contains($n | ascii_downcase))] end)
            | .[] | "\(.projectId)\t\(.name)"')
        [ -n "$matches" ] || die "no project matching '$ARG_NAME'. Run '$0 projects' to list them."
    else
        local total remote prefix
        total=$(printf '%s' "$HTTP_BODY" | jq 'length')
        if [ "$total" = 1 ]; then
            printf '%s' "$HTTP_BODY" | jq -r '.[0].projectId'
            return
        fi
        git rev-parse --git-dir >/dev/null 2>&1 \
            || die "several projects in this organization and this is not a git repository.
Pass --name '<project name>', or --project <id>. Run '$0 projects' to list them."

        remote=$(normalize_repo_url "$(git remote get-url origin 2>/dev/null)")
        prefix=$(git rev-parse --show-prefix 2>/dev/null)
        prefix="${prefix%/}"

        local in_repo
        in_repo=$(printf '%s' "$HTTP_BODY" | jq -r --arg remote "$remote" '
            .[] | select((.source // "")
                | ascii_downcase
                | sub("^[a-z+]+://"; "") | sub("^[^@/]+@"; "") | sub("^[^/:]+[:/]"; "")
                | sub("\\.git$"; "")
                | . == $remote)
            | "\(.projectId)\t\(.name)\t\((.sourcePath // "") | sub("/$"; ""))"')
        [ -n "$in_repo" ] || die "no project in this organization points at $remote.
Pass --name '<project name>', or --project <id>. Run '$0 projects' to list them."

        # Several projects can share one repository, each rooted at its own sourcePath. Narrow by
        # the path this is being run from; keep the repo-wide list when that matches nothing, so
        # the error can name the real candidates rather than claim there are none.
        matches=$(printf '%s\n' "$in_repo" | awk -F'\t' -v p="$prefix" '$3 == p { print $1 "\t" $2 }')
        if [ -z "$matches" ]; then
            if [ "$(printf '%s\n' "$in_repo" | grep -c . )" = 1 ]; then
                matches=$(printf '%s\n' "$in_repo" | cut -f1,2)
            else
                die "several projects share this repository, none rooted at '${prefix:-the repo root}'.
Run the deploy from one of their directories, or pass --project with one of:
$(printf '%s\n' "$in_repo" | awk -F'\t' '{ printf "  %s\t%s\t(%s)\n", $1, $2, ($3 == "" ? "repo root" : $3) }')"
            fi
        fi
    fi

    if [ "$(printf '%s\n' "$matches" | grep -c . )" = 1 ]; then
        printf '%s' "$matches" | cut -f1
    else
        die "this matches several projects. Pass --project with one of:
$matches"
    fi
}

fetch_project_deployments() {
    load_token
    require_project
    resolve_org
    # `type=full` is the only shape carrying commitHash, which the duplicate check needs; the
    # short shape omits it. `includeStatus` is declared as a string in the spec, so it is sent
    # as "true".
    request GET "$API/projects/$ARG_PROJECT/deployments?orgId=$ORG_ID&type=full&includeStatus=true&limit=${ARG_LIMIT:-1000}"
    require_ok
}

cmd_deployments() {
    if [ -n "$ARG_PROJECT" ]; then
        fetch_project_deployments
    else
        load_token
        resolve_org
        request GET "$API/deployments?orgId=$ORG_ID&limit=${ARG_LIMIT:-10}"
        require_ok
        HTTP_BODY=$(printf '%s' "$HTTP_BODY" | jq '.deployments // .')
    fi

    if [ "$ARG_JSON" = 1 ]; then
        printf '%s\n' "$HTTP_BODY" | jq .
        return
    fi
    printf '%s' "$HTTP_BODY" | jq -r '.[] |
        "\(.deploymentId)\t\(.deploymentName // .name // "")\t\(.status // "")\t\(.stage // "")\t\((.commitHash // "")[0:8])\t\(if .isMain then "MAIN" else "" end)"' \
        | table
}

# A deployment whose stage is terminate or delete is on its way out and does not count as an
# existing deployment of the commit.
find_live_deployments_on_commit() {
    fetch_project_deployments
    FOUND_DEPLOYMENTS=$(printf '%s' "$HTTP_BODY" | jq --arg sha "$1" '[.[]
        | select((.commitHash // "") == $sha)
        | select((.stage // "") as $s | ($s != "terminate" and $s != "delete"))]')
}

cmd_find_commit() {
    [ -n "$ARG_COMMIT" ] || die "pass --commit SHA"
    find_live_deployments_on_commit "$ARG_COMMIT"
    if [ "$ARG_JSON" = 1 ]; then
        printf '%s\n' "$FOUND_DEPLOYMENTS" | jq .
        return
    fi
    if [ "$(printf '%s' "$FOUND_DEPLOYMENTS" | jq 'length')" = 0 ]; then
        echo "No live deployment on $ARG_COMMIT."
        return
    fi
    printf '%s' "$FOUND_DEPLOYMENTS" | jq -r '.[] |
        "\(.deploymentId)\t\(.deploymentName // "")\t\(.status // "")\t\(.stage // "")"' \
        | table
}

cmd_deployment_get() {
    local path="$1"
    load_token
    require_deployment
    resolve_org
    request GET "$API/deployments/$DEPLOYMENT_ID${path}?orgId=$ORG_ID"
    require_ok
    printf '%s\n' "$HTTP_BODY" | jq .
}

cmd_status() {
    load_token
    require_deployment
    resolve_org
    request GET "$API/deployments/$DEPLOYMENT_ID/status?orgId=$ORG_ID"
    require_ok
    if [ "$ARG_JSON" = 1 ]; then
        printf '%s\n' "$HTTP_BODY" | jq .
        return
    fi
    printf '%s' "$HTTP_BODY" | jq -r '
        "Status: \(.status)  Stage: \(.stage)",
        (.latestStatuses[]? | "  \(.service): \(.status)")'
}

cmd_logs() {
    load_token
    require_project
    resolve_org
    local url="$API/logs?orgId=$ORG_ID&projectId=$ARG_PROJECT&limit=${ARG_LIMIT:-200}"
    [ -n "$ARG_DEPLOYMENT" ] && url="$url&deploymentId=$ARG_DEPLOYMENT"
    request GET "$url"
    require_ok
    printf '%s\n' "$HTTP_BODY" | jq .
}

cmd_wait() {
    require_deployment
    local id="$DEPLOYMENT_ID"
    local deadline=$(( $(date +%s) + WAIT_MAX_SECONDS ))

    while :; do
        load_token
        resolve_org
        request GET "$API/deployments/$id/status?orgId=$ORG_ID"
        require_ok

        local status stage
        status=$(printf '%s' "$HTTP_BODY" | jq -r '.status')
        stage=$(printf '%s' "$HTTP_BODY" | jq -r '.stage')
        echo "$(date +%H:%M:%S)  $status ($stage)"

        case "$status" in
            RUN|FINISH)
                echo "Deployment $id is $status."
                report_deployment "$id"
                return 0
                ;;
            FAILED)
                echo "Deployment $id FAILED at stage '$stage'." >&2
                report_deployment "$id" >&2
                return 1
                ;;
        esac

        if [ "$(date +%s)" -ge "$deadline" ]; then
            cat <<EOF
Still $status after $(( WAIT_MAX_SECONDS / 60 )) minutes. The deployment is not failed, only slow.
Check it with:
  $0 status $id
  $0 details $id
EOF
            return 2
        fi
        sleep "$WAIT_INTERVAL"
    done
}

cmd_deploy() {
    [ -n "$ARG_COMMIT" ] || die "pass --commit SHA. Resolve a branch or tag locally first:
  git rev-parse <ref>"
    load_token
    require_project
    resolve_org

    if [ "$ARG_FORCE" = 0 ]; then
        find_live_deployments_on_commit "$ARG_COMMIT"
        if [ "$(printf '%s' "$FOUND_DEPLOYMENTS" | jq 'length')" != 0 ]; then
            echo "Commit $ARG_COMMIT is already deployed:" >&2
            printf '%s' "$FOUND_DEPLOYMENTS" | jq -r '.[] |
                "  \(.deploymentId)  \(.deploymentName // "")  \(.status // "")/\(.stage // "")"' >&2
            die "no deployment created. Pass --force to create another one anyway."
        fi
    fi

    resolve_branch_label "$ARG_COMMIT"

    local body
    body=$(jq -nc \
        --arg org "$ORG_ID" \
        --arg project "$ARG_PROJECT" \
        --arg sha "$ARG_COMMIT" \
        --arg branch "$BRANCH_LABEL" \
        --args \
        '{orgId: $org, projectId: $project, commitSha: $sha, extraPackageJson: $ARGS.positional}
         + (if $branch == "" then {} else {branch: $branch} end)' \
        "${EXTRA_PACKAGE_JSON[@]}")

    request POST "$API/deployments" "$body"
    require_ok

    local id created
    id=$(printf '%s' "$HTTP_BODY" | jq -r '.deploymentId')
    # Saved before resolving the URL, which issues its own request and overwrites HTTP_BODY.
    created="$HTTP_BODY"
    if [ "$ARG_JSON" = 1 ]; then
        resolve_deployment_url "$id"
        printf '%s' "$created" | jq --arg u "$DEPLOYMENT_URL" '. + {url: ($u | select(. != ""))}'
    else
        echo "Created deployment $id from $ARG_COMMIT."
        report_deployment "$id"
        echo "  Follow it:     $0 wait $id"
    fi
}

cmd_promote() {
    load_token
    require_deployment
    resolve_org
    request PUT "$API/deployments/$DEPLOYMENT_ID" \
        "$(jq -nc --arg org "$ORG_ID" '{orgId: $org, action: "promote"}')"
    require_ok
    echo "Promoted $DEPLOYMENT_ID to the project's main deployment."
    report_deployment "$DEPLOYMENT_ID"
}

usage() {
    awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$SELF" 2>/dev/null \
        || echo "Usage: datasqrl-cloud.sh <login|whoami|logout|orgs|projects|project-id|deployments|deployment|status|details|logs|find-commit|wait|deploy|promote>"
}

# `dispatch; exit $?` must stay one command list: bash reads this file incrementally, so editing
# it during a 15-minute `wait` leaves the trailing read at a stale offset and it mis-parses.
dispatch() {
    case "$SUBCOMMAND" in
        login) do_login ;;
        whoami) do_whoami ;;
        logout)
            [ -f "$CACHE_FILE" ] && jq --arg k "$(cache_key)" 'del(.[$k])' "$CACHE_FILE" \
                >"$CACHE_FILE.tmp" && mv "$CACHE_FILE.tmp" "$CACHE_FILE"
            echo "Signed out of $(cache_key)."
            ;;
        orgs) cmd_orgs ;;
        projects) cmd_projects ;;
        project-id) cmd_project_id ;;
        deployments) cmd_deployments ;;
        deployment) cmd_deployment_get "" ;;
        status) cmd_status ;;
        details) cmd_deployment_get "/details" ;;
        logs) cmd_logs ;;
        find-commit) cmd_find_commit ;;
        wait) cmd_wait ;;
        deploy) cmd_deploy ;;
        promote) cmd_promote ;;
        help|"") usage ;;
        *)
            echo "Error: unknown subcommand '$SUBCOMMAND'." >&2
            echo "" >&2
            usage >&2
            exit 1
            ;;
    esac
}

dispatch; exit $?

