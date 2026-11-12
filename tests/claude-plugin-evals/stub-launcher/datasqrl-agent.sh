#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Stub of scripts/datasqrl-agent.sh for the cases in stub-launcher-tests/. run-stub-launcher-tests.sh
# puts it in place of the real launcher in a copy of the plugin.
#
# The stub starts no Docker container. It does three things:
#   1. It adds one line to .datasqrl_agent_stub_calls.jsonl in the working directory for each call,
#      for example {"arguments": ["rename x", "--mode", "patch", "--detach"]}. A grader checks
#      the arguments of each call in this file. The real launcher writes no such file.
#   2. It prints the answer that the real launcher prints for that call.
#   3. For a run with --detach, it writes .datasqrl_agent_results.json, as the agent container does
#      at the end of a run.

stub_calls_file="$PWD/.datasqrl_agent_stub_calls.jsonl"
results_file="$PWD/.datasqrl_agent_results.json"

# Prints one argument as a JSON string: backslashes, double quotes, tabs and newlines escaped.
json_string() {
    local text="$1"
    text="${text//\\/\\\\}"
    text="${text//\"/\\\"}"
    text="${text//$'\t'/\\t}"
    text="${text//$'\n'/\\n}"
    printf '"%s"' "$text"
}

{
    printf '{"arguments": ['
    separator=""
    for argument in "$@"; do
        printf '%s%s' "$separator" "$(json_string "$argument")"
        separator=", "
    done
    printf ']}\n'
} >> "$stub_calls_file"

# Prints the value of --mode, given as "--mode patch" or as "--mode=patch".
mode_argument() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --mode) printf '%s' "${2:-}"; return ;;
            --mode=*) printf '%s' "${1#--mode=}"; return ;;
        esac
        shift
    done
}

case " $* " in
    *" --image-exists "*)
        echo "datasqrl/codeagent:latest is present · edition: os · version: 0.0.0-stub"
        ;;
    *" --show-options "*)
        cat <<'EOF'
Harnesses: claude-code (default)
Default provider: anthropic
Default models: planning claude-opus-5 · implementation claude-sonnet-5 · patch claude-sonnet-5
Providers:
  anthropic   ready       ANTHROPIC_API_KEY set
  openai      not ready   OPENAI_API_KEY not set
  bedrock     not ready   AWS_PROFILE not set
EOF
        ;;
    *" --check-config "*)
        echo "Harness   claude-code"
        echo "Provider  anthropic · ANTHROPIC_API_KEY set"
        echo "Status READY"
        ;;
    *" --detach "*)
        run_mode="$(mode_argument "$@")"
        printf '{"runs": [{"success": true, "mode": "%s", "refinements": 0, "issue_score": 0, "issue_count": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "code_check_status": "complete", "llm_judge_status": "complete", "issues": []}]}\n' \
            "${run_mode:-patch}" > "$results_file"
        echo "datasqrl-agent-$(basename "$PWD")-3f9a2c1b"
        echo "Running in the background as a detached container. This session can close; the run continues."
        echo "  wait for it:      datasqrl-agent.sh --wait"
        echo "  status:           datasqrl-agent.sh --status"
        echo "  stop:             datasqrl-agent.sh --stop"
        ;;
    *" --wait "*|*" --status "*)
        run_mode="$(sed -n 's/.*"mode": "\([a-z]*\)".*/\1/p' "$results_file" 2>/dev/null)"
        echo "Finished · success · ${run_mode:-patch} · 0 refinement(s) · 0 issue(s) (0 critical, 0 high, 0 medium, 0 low) · score 0"
        ;;
    *)
        echo "eval stub: no answer for these arguments: $*" >&2
        exit 2
        ;;
esac
