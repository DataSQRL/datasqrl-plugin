#!/bin/bash
# Install the DataSQRL skills into a repository for coding agents that have no plugin system.
#
# Claude Code, Codex and Cursor all install this directory as a PLUGIN and do not need this
# script — see the README. GitHub Copilot has no plugin/marketplace concept: it discovers skills
# from directories inside the repository you are working in, so the files have to be copied there.
#
# Usage, from anywhere:
#   ./install-skills.sh [target-repo]        # defaults to the current directory
#
# Copies:
#   <target>/.github/skills/<skill>/         the DataSQRL skills
#   <target>/.agents/skills/<skill>/         same skills, for agents that read this location
#
# The launcher itself is NOT copied — it must be on PATH. See "Requirements" below.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-$PWD}"

if [ ! -d "$SRC_DIR/skills" ]; then
    echo "Error: no skills/ directory next to this script ($SRC_DIR)." >&2
    exit 1
fi

if [ ! -d "$TARGET" ]; then
    echo "Error: target '$TARGET' is not a directory." >&2
    exit 1
fi

# Both locations are read by Copilot; .agents/skills is also read by Codex when it is not
# installed as a plugin. Writing both costs nothing and removes a "which one does my agent use?"
# support question.
for dest in "$TARGET/.github/skills" "$TARGET/.agents/skills"; do
    mkdir -p "$dest"
    # Copy per-skill so unrelated skills already present in the target are left alone.
    for skill in "$SRC_DIR"/skills/*/; do
        name="$(basename "$skill")"
        rm -rf "${dest:?}/$name"
        cp -R "$skill" "$dest/$name"
    done
    echo "Installed $(find "$SRC_DIR"/skills -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ') skills into $dest"
done

echo
if command -v datasqrl-agent.sh >/dev/null 2>&1; then
    echo "datasqrl-agent.sh found on PATH: $(command -v datasqrl-agent.sh)"
else
    cat <<EOF
NOTE: datasqrl-agent.sh is not on your PATH, and the skills invoke it by that name.
Install it with:

  curl -fsSL https://raw.githubusercontent.com/DataSQRL/datasqrl-plugin/main/scripts/datasqrl-agent.sh \\
    -o /usr/local/bin/datasqrl-agent.sh && chmod +x /usr/local/bin/datasqrl-agent.sh
EOF
fi
