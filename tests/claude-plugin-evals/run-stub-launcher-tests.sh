#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Runs the cases in stub-launcher-tests/ with the stub launcher in place of scripts/datasqrl-agent.sh.
#
# The skills call the launcher by its full path in the plugin, so the stub must be in the plugin
# itself. This script copies the plugin to a temporary folder, replaces scripts/datasqrl-agent.sh
# in the copy with stub-launcher/datasqrl-agent.sh, and runs claude plugin eval on the copy. The
# real scripts/datasqrl-agent.sh does not change. The copy is deleted at the end.
#
# Usage, from any directory:
#   tests/claude-plugin-evals/run-stub-launcher-tests.sh [claude plugin eval options]
#
# Examples:
#   tests/claude-plugin-evals/run-stub-launcher-tests.sh --threshold 0.8
#   tests/claude-plugin-evals/run-stub-launcher-tests.sh --runs 1 --case patch-small-change-runs-patch
set -euo pipefail

eval_root="$(cd "$(dirname "$0")" && pwd)"
plugin_root="$(cd "$eval_root/../.." && pwd)"
eval_dir="tests/claude-plugin-evals/stub-launcher-tests"
results_dir="$eval_root/stub-launcher-tests/results/$(date -u +%Y-%m-%dT%H-%M-%SZ)"

plugin_copy="$(mktemp -d "${TMPDIR:-/tmp}/datasqrl-plugin-with-stub-launcher.XXXXXX")"
trap 'rm -rf "$plugin_copy"' EXIT

rsync -a \
    --exclude .git --exclude results --exclude __pycache__ --exclude .pytest_cache \
    "$plugin_root"/ "$plugin_copy"/
cp "$eval_root/stub-launcher/datasqrl-agent.sh" "$plugin_copy/scripts/datasqrl-agent.sh"
chmod +x "$plugin_copy/scripts/datasqrl-agent.sh"

mkdir -p "$results_dir"
echo "Plugin copy with the stub launcher: $plugin_copy"
echo "Results: $results_dir"

# --trust-plugin: the copy is a new folder for each run, so the first-run trust prompt would ask
# every time. The copy holds only this repository's own files.
claude plugin eval "$plugin_copy" \
    --eval-dir "$eval_dir" \
    --output-dir "$results_dir" \
    --scaffold \
    --ablation none \
    --allow-tools Bash \
    --trust-plugin \
    --no-publish \
    "$@"
