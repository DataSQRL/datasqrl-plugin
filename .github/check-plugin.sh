#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Checks that this repository installs as a working plugin. CI runs it on every pull request and
# before every release; run it locally before opening a pull request.
#
# Usage, from the repository root:
#   .github/check-plugin.sh              # every check
#   .github/check-plugin.sh --tag 1.2.3  # also require the tag to match the manifest version
#
# Needs bash, python3 and, when installed, shellcheck. Without shellcheck the lint step is skipped
# with a notice; CI always has it.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

TAG=""
if [ "${1:-}" = "--tag" ]; then
    TAG="${2:?--tag needs a value such as 1.2.3}"
fi

failures=0
fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

# 1. Scripts: real files, executable, valid bash, and clean under shellcheck. A plugin host copies
#    the plugin into a cache on install, so a symlink would arrive empty and every skill would fail
#    to find its script.
scripts=(scripts/datasqrl-agent.sh scripts/datasqrl-cloud.sh install-skills.sh .github/check-plugin.sh)
for f in "${scripts[@]}"; do
    if [ ! -e "$f" ]; then fail "$f is missing"; continue; fi
    [ -L "$f" ] && fail "$f is a symlink; it must be a real file"
    [ -x "$f" ] || fail "$f is not executable (git update-index --chmod=+x $f)"
    bash -n "$f" || fail "$f is not valid bash"
done
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S error "${scripts[@]}" || fail "shellcheck reported errors"
else
    echo "NOTICE: shellcheck is not installed; skipping the lint step." >&2
fi

# 2. Manifests: each host reads its own, so each must parse, and all must carry one version.
manifests=(.claude-plugin/marketplace.json .claude-plugin/plugin.json .codex-plugin/plugin.json .cursor-plugin/plugin.json mcp.json)
for m in "${manifests[@]}"; do
    [ -f "$m" ] || { fail "$m is missing"; continue; }
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$m" || fail "$m is not valid JSON"
done
versions=$(python3 - <<'EOF'
import json
for m in (".claude-plugin/plugin.json", ".codex-plugin/plugin.json", ".cursor-plugin/plugin.json"):
    try:
        print(m, json.load(open(m)).get("version", "<none>"))
    except Exception:
        print(m, "<unreadable>")
EOF
)
VERSION=$(echo "$versions" | awk 'NR==1{print $2}')
if [ "$(echo "$versions" | awk '{print $2}' | sort -u | wc -l | tr -d ' ')" != "1" ]; then
    fail "the manifests disagree on the version:"$'\n'"$versions"
fi

# 3. The Claude manifest keeps the default skills/ scan; a skills key would hide every skill it omits.
python3 -c 'import json,sys; sys.exit("skills" in json.load(open(".claude-plugin/plugin.json")))' \
    || fail ".claude-plugin/plugin.json declares a skills key, which hides every skill it does not list"

# 4. Skills: every directory has a SKILL.md whose name matches the directory.
shopt -s nullglob
skill_dirs=(skills/*/)
[ "${#skill_dirs[@]}" -ge 1 ] || fail "no skills found under skills/"
for d in "${skill_dirs[@]}"; do
    s=$(basename "$d")
    if [ ! -f "$d/SKILL.md" ]; then fail "skills/$s/SKILL.md is missing"; continue; fi
    grep -qx "name: $s" "$d/SKILL.md" || fail "skills/$s/SKILL.md has no 'name: $s' line"
done

# 5. Skills reach users exactly as written, so maintainer notes belong in CONTRIBUTING.md. An HTML
#    comment is invisible when rendered but is read by the agent as plain text.
if grep -rn '<!--' skills/; then
    fail "an HTML comment is in skills/; move maintainer notes to CONTRIBUTING.md"
fi

# 6. MCP: each host declares the datasqrl server and gets its token from the cloud script. Codex
#    loads the server only through the manifest's mcpServers path.
python3 - <<'EOF' || fail "an MCP server declaration is missing or broken"
import json, os, sys

def server(path, mcp_servers):
    entry = mcp_servers.get("datasqrl") if isinstance(mcp_servers, dict) else None
    if not entry:
        problems.append(f"{path}: no datasqrl MCP server")
    return entry or {}

problems = []
claude = server(".claude-plugin/plugin.json", json.load(open(".claude-plugin/plugin.json")).get("mcpServers"))
if "mcp-headers" not in claude.get("headersHelper", ""):
    problems.append(".claude-plugin/plugin.json: datasqrl needs a headersHelper that runs mcp-headers")
codex_file = json.load(open(".codex-plugin/plugin.json")).get("mcpServers")
if not isinstance(codex_file, str) or not os.path.isfile(codex_file):
    problems.append(".codex-plugin/plugin.json: mcpServers must name an existing file")
else:
    codex = server(codex_file, json.load(open(codex_file)).get("mcpServers"))
    if codex.get("args", [])[-1:] != ["mcp-bridge"]:
        problems.append(f"{codex_file}: datasqrl must run mcp-bridge")
cursor = server(".cursor-plugin/plugin.json", json.load(open(".cursor-plugin/plugin.json")).get("mcpServers"))
if cursor.get("args", [])[-1:] != ["mcp-bridge"]:
    problems.append(".cursor-plugin/plugin.json: datasqrl must run mcp-bridge")
for p in problems:
    print("  " + p, file=sys.stderr)
sys.exit(1 if problems else 0)
EOF

# 7. Release only: the tag is the manifest version, plain SemVer with no "v" prefix.
if [ -n "$TAG" ] && [ "$TAG" != "$VERSION" ]; then
    fail "tag $TAG does not match the manifest version $VERSION (expected $VERSION)"
fi

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed." >&2
    exit 1
fi
echo "All checks passed (version $VERSION, ${#skill_dirs[@]} skills)."
