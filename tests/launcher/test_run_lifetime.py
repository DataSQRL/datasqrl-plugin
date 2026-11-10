"""--status, --stop, --wait and --detach, against a fake `docker` that keeps run state."""

from __future__ import annotations

import time

from tests.launcher.fakes.docker_runs import (  # noqa: F401
    LAUNCHER,
    project,
    launcher,
    start_run,
    write_trail,
    write_result,
    run_result,
)


class TestStatus:
    def test_running_shows_last_step_and_activity(self, project):
        proj, fake, env = project
        now = int(time.time())
        start_run(fake, now - 600)
        write_trail(proj, "+00:00:00  RUN    Run started · implementation",
                    "+00:01:40  STEP   Iteration 1 · implementing",
                    "+00:07:40  TEXT   Step 7 done. Now step 8.",
                    "                  second line of that text")
        r = launcher(proj, env, "--status")
        assert r.returncode == 0, r.stderr
        line = r.stdout.strip()
        assert line.startswith("Running · implementation · started 10m ago · Iteration 1 · implementing · last: Step 7 done. Now step 8. (")
        assert line.endswith(" ago)")

    def test_running_without_activity_yet(self, project):
        proj, fake, env = project
        start_run(fake, int(time.time()) - 120)   # minutes, so a second boundary cannot flip the text
        write_trail(proj, "+00:00:00  RUN    Run started · planning")
        r = launcher(proj, env, "--status")
        assert r.stdout.strip() == "Running · implementation · started 2m ago · Run started · planning"

    def test_running_with_done_record_reports_finishing(self, project):
        proj, fake, env = project
        start_run(fake, int(time.time()) - 600)
        write_trail(proj, "+00:10:00  DONE   Finished · success · implementation · pipeline · 1 refinement(s) · 0 issue(s) (0 critical, 0 high, 0 medium, 0 low) · score 0")
        r = launcher(proj, env, "--status")
        assert r.stdout.strip() == "Finishing · Finished · success · implementation · pipeline · 1 refinement(s) · 0 issue(s) (0 critical, 0 high, 0 medium, 0 low) · score 0"

    def test_not_running_reports_last_result(self, project):
        proj, fake, env = project
        write_result(proj, run_result(success=False, refinements=2, severities=["CRITICAL", "HIGH", "LOW"]))
        r = launcher(proj, env, "--status")
        assert r.stdout.strip() == (
            "No run in progress. Last result: failed · implementation · pipeline · 2 refinement(s) · "
            "3 issue(s) (1 critical, 1 high, 0 medium, 1 low) · score 126"
        )

    def test_a_run_no_judge_scored_shows_no_issues(self, project):
        """Planning, patch and --disable-verification runs record `issue_score: null`."""
        proj, fake, env = project
        write_result(proj, run_result(mode="patch", severities=None))
        r = launcher(proj, env, "--status")
        assert r.stdout.strip() == "No run in progress. Last result: success · patch · pipeline · 1 refinement(s)"

    def test_complete_statuses_add_no_note(self, project):
        proj, fake, env = project
        write_result(proj, run_result(severities=["HIGH"], code_check_status="complete",
                                      llm_judge_status="complete"))
        r = launcher(proj, env, "--status")
        assert r.stdout.strip().endswith("1 issue(s) (0 critical, 1 high, 0 medium, 0 low) · score 25")

    def test_failed_llm_judges_keep_the_score_and_add_a_note(self, project):
        """The code checks still scored the run, so the line keeps the score and names both kinds of check."""
        proj, fake, env = project
        write_result(proj, run_result(severities=["HIGH"], code_check_status="complete",
                                      llm_judge_status="failed"))
        r = launcher(proj, env, "--status")
        assert r.stdout.strip() == (
            "No run in progress. Last result: success · implementation · pipeline · 1 refinement(s) · "
            "1 issue(s) (0 critical, 1 high, 0 medium, 0 low) · score 25 "
            "[code checks: complete, LLM judges: failed]"
        )

    def test_partial_code_checks_without_llm_judges_name_only_the_code_checks(self, project):
        proj, fake, env = project
        write_result(proj, run_result(severities=["HIGH"], code_check_status="partial"))
        r = launcher(proj, env, "--status")
        assert r.stdout.strip().endswith("· score 25 [code checks: partial]")

    def test_nothing_ever_ran(self, project):
        proj, fake, env = project
        r = launcher(proj, env, "--status")
        assert r.stdout.strip() == "No run in progress for this project, and no previous result."


class TestStop:
    def test_stop_stops_the_named_container(self, project):
        proj, fake, env = project
        start_run(fake, int(time.time()))
        r = launcher(proj, env, "--stop")
        assert r.stdout.strip() == "Stopped the run for this project."
        args = (fake / "stop_args").read_text().split()
        assert args[0] == "stop" and args[-1].startswith("datasqrl-agent-proj-")

    def test_stop_without_a_run(self, project):
        proj, fake, env = project
        r = launcher(proj, env, "--stop")
        assert r.stdout.strip() == "No run in progress for this project."


class TestDetach:
    def test_detached_launch_prints_run_name_and_hand_off(self, project, tmp_path):
        """A detached launch prints the run name, then copy-pasteable commands for a second terminal."""
        proj, fake, env = project
        env = {**env, "HOME": str(tmp_path / "home"), "ANTHROPIC_API_KEY": "sk-test",
               "AWS_ACCESS_KEY_ID": "x", "AWS_SECRET_ACCESS_KEY": "y"}
        (tmp_path / "home").mkdir()
        r = launcher(proj, env, "--mode", "implementation", "--detach")
        assert r.returncode == 0, r.stderr
        lines = r.stdout.splitlines()
        assert lines[0].startswith("datasqrl-agent-proj-")
        assert lines[1].startswith("Running in the background as a detached container.")
        assert lines[2].strip() == f"follow it live:   tail -f '{proj.resolve()}/.datasqrl/datasqrl-agent-progress.txt'"
        assert lines[3].strip() == f"wait for it:      cd '{proj.resolve()}' && '{LAUNCHER}' --wait"
        assert lines[4].strip() == f"status:           cd '{proj.resolve()}' && '{LAUNCHER}' --status"
        assert lines[5].strip() == f"stop:             cd '{proj.resolve()}' && '{LAUNCHER}' --stop"


RESULT_OK = run_result(mode="planning", refinements=0, severities=None)
RESULT_OK_LINE = "No run in progress. Last result: success · planning · pipeline · 0 refinement(s)"

# The history: newest run first, so the launcher's `grep -m1` reads the run that just finished
# and the earlier ones stay on disk. write_result takes the runs oldest first.
RESULT_HISTORY = (
    run_result(mode="planning", success=False, scenario="catalog", refinements=0,
               severities=["CRITICAL"] * 7),
    run_result(severities=["HIGH", "MEDIUM", "MEDIUM"]),
)
RESULT_HISTORY_LINE = (
    "No run in progress. Last result: success · implementation · pipeline · "
    "1 refinement(s) · 3 issue(s) (0 critical, 1 high, 2 medium, 0 low) · score 35"
)


class TestWait:
    def test_wait_blocks_on_the_container_then_prints_the_result(self, project):
        """`docker wait <run>` is the block; the status line after it is the whole output."""
        proj, fake, env = project
        start_run(fake, int(time.time()) - 60)
        write_result(proj, RESULT_OK)
        r = launcher(proj, env, "--wait")
        assert r.returncode == 0, r.stderr
        assert r.stdout.strip() == RESULT_OK_LINE
        args = (fake / "wait_args").read_text().split()
        assert args[0] == "wait" and args[-1].startswith("datasqrl-agent-proj-")

    def test_wait_exits_with_the_containers_exit_code(self, project):
        """A stopped run exits 143 in the container; --wait passes that through so `&&` chains see it."""
        proj, fake, env = project
        start_run(fake, int(time.time()))
        (fake / "exit_code").write_text("143\n")
        r = launcher(proj, env, "--wait")
        assert r.returncode == 143
        assert r.stdout.strip() == "No run in progress for this project, and no previous result."

    def test_wait_without_a_run_prints_the_status_at_once(self, project):
        """Already gone (finished and --rm'd, or never started): docker's error is swallowed, the status line still tells what happened."""
        proj, fake, env = project
        write_result(proj, RESULT_OK)
        r = launcher(proj, env, "--wait")
        assert r.returncode == 0
        assert r.stdout.strip() == RESULT_OK_LINE
        assert "No such container" not in r.stderr


class TestStatusWithCount:
    def test_status_n_prints_recent_lines_then_status(self, project):
        proj, fake, env = project
        start_run(fake, int(time.time()) - 60)
        write_trail(proj, "+00:00:00  RUN    Run started · implementation",
                    "+00:00:10  STEP   Iteration 0 · implementing",
                    "+00:00:20  TEXT   Step 1 done.")
        r = launcher(proj, env, "--status", "2")
        assert r.returncode == 0, r.stderr
        lines = r.stdout.splitlines()
        assert lines[:2] == ["+00:00:10  STEP   Iteration 0 · implementing", "+00:00:20  TEXT   Step 1 done."]
        assert lines[2].startswith("Running · implementation · started 1m ago · Iteration 0 · implementing · last: Step 1 done. (")

    def test_status_n_after_the_run_shows_kept_trail_and_last_result(self, project):
        proj, fake, env = project
        done = ("+00:46:51  DONE   Finished · success · implementation · pipeline · 1 refinement(s) · "
                "3 issue(s) (0 critical, 1 high, 2 medium, 0 low) · score 35")
        write_trail(proj, done)
        write_result(proj, run_result(severities=["HIGH", "MEDIUM", "MEDIUM"]))
        r = launcher(proj, env, "--status", "40")
        assert r.returncode == 0
        assert r.stdout.splitlines() == [
            done,
            "No run in progress. Last result: success · implementation · pipeline · 1 refinement(s) · "
            "3 issue(s) (0 critical, 1 high, 2 medium, 0 low) · score 35",
        ]

    def test_status_n_takes_the_last_n_physical_lines(self, project):
        proj, fake, env = project
        start_run(fake, int(time.time()) - 5)
        write_trail(proj, *[f"+00:00:{i:02d}  TEXT   line {i}" for i in range(50)])
        r = launcher(proj, env, "--status", "40")
        lines = r.stdout.splitlines()
        assert len(lines) == 41
        assert lines[0].endswith("line 10")
        assert lines[-1].startswith("Running · implementation")

    def test_status_n_without_trail_prints_status_only(self, project):
        proj, fake, env = project
        r = launcher(proj, env, "--status", "40")
        assert r.stdout.strip() == "No run in progress for this project, and no previous result."

    def test_plain_status_stays_one_line_even_with_a_trail(self, project):
        proj, fake, env = project
        start_run(fake, int(time.time()) - 5)
        write_trail(proj, "+00:00:00  RUN    Run started · implementation",
                    "+00:00:03  TEXT   hello")
        r = launcher(proj, env, "--status")
        assert len(r.stdout.splitlines()) == 1


class TestResultHistory:
    """`.datasqrl_agent_results.json` holds every run for the project, newest first. The launcher
    parses it with `grep -m1`, so the newest run has to be what --status and --wait report."""

    def test_status_reports_the_newest_run_not_an_earlier_one(self, project):
        proj, fake, env = project
        write_result(proj, *RESULT_HISTORY)

        r = launcher(proj, env, "--status")

        assert r.returncode == 0, r.stderr
        assert RESULT_HISTORY_LINE in r.stdout
        # The older planning run's values must not leak into the line.
        assert "planning" not in r.stdout
        assert "catalog" not in r.stdout
        assert "7 issue(s)" not in r.stdout

    def test_wait_reports_the_newest_run(self, project):
        proj, fake, env = project
        write_result(proj, *RESULT_HISTORY)

        r = launcher(proj, env, "--wait")

        assert r.returncode == 0, r.stderr
        assert RESULT_HISTORY_LINE in r.stdout
