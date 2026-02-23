"""Unit tests for benchmark/prereqs.sh (Phase 0 prerequisites checker)."""

import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PREREQS_SCRIPT = REPO_ROOT / "benchmark" / "prereqs.sh"


class TestPrereqsScript:
    """Test prereqs.sh static mode (no --full flag)."""

    def test_script_exists(self):
        """Verify prereqs.sh exists at expected path."""
        assert PREREQS_SCRIPT.exists()

    def test_script_is_executable_bash(self):
        """Verify script shebang references bash."""
        first_line = PREREQS_SCRIPT.read_text().splitlines()[0]
        assert "bash" in first_line

    def test_static_mode_runs_without_error(self):
        """Static mode (no --full) should pass with current repo state."""
        result = subprocess.run(
            ["bash", str(PREREQS_SCRIPT)],
            capture_output=True,
            text=True,
            timeout=30,
            cwd=str(REPO_ROOT),
        )
        assert result.returncode == 0, f"prereqs.sh failed:\n{result.stdout}\n{result.stderr}"

    def test_static_mode_skips_api_checks(self):
        """Without --full, API-calling steps should be skipped."""
        result = subprocess.run(
            ["bash", str(PREREQS_SCRIPT)],
            capture_output=True,
            text=True,
            timeout=30,
            cwd=str(REPO_ROOT),
        )
        assert "SKIP" in result.stdout
        # Steps 4, 6, 9, 10 should be skipped
        assert "Baseline hook isolation" in result.stdout
        assert "claude -p subprocess behavior" in result.stdout
        assert "Tool restriction enforcement" in result.stdout
        assert "Concurrency probe" in result.stdout

    def test_static_mode_checks_version(self):
        """Verify static mode checks Claude Code version."""
        result = subprocess.run(
            ["bash", str(PREREQS_SCRIPT)],
            capture_output=True,
            text=True,
            timeout=30,
            cwd=str(REPO_ROOT),
        )
        assert "Claude Code version" in result.stdout
        assert "PASS" in result.stdout

    def test_static_mode_checks_archive(self):
        """Verify static mode checks archive and swebench directories."""
        result = subprocess.run(
            ["bash", str(PREREQS_SCRIPT)],
            capture_output=True,
            text=True,
            timeout=30,
            cwd=str(REPO_ROOT),
        )
        assert "benchmark/archive/ exists" in result.stdout
        assert "benchmark/swebench/results/ exists" in result.stdout

    def test_unknown_argument_fails(self):
        """Verify unknown arguments cause nonzero exit."""
        result = subprocess.run(
            ["bash", str(PREREQS_SCRIPT), "--bogus"],
            capture_output=True,
            text=True,
            timeout=10,
            cwd=str(REPO_ROOT),
        )
        assert result.returncode != 0
        assert "Unknown argument" in result.stdout or "Unknown argument" in result.stderr

    def test_summary_section_present(self):
        """Verify output contains prerequisites checklist summary."""
        result = subprocess.run(
            ["bash", str(PREREQS_SCRIPT)],
            capture_output=True,
            text=True,
            timeout=30,
            cwd=str(REPO_ROOT),
        )
        assert "Prerequisites Checklist" in result.stdout
        assert "Results:" in result.stdout

    def test_step_count_is_11(self):
        """All 11 check steps should appear in output (summary is unnumbered)."""
        result = subprocess.run(
            ["bash", str(PREREQS_SCRIPT)],
            capture_output=True,
            text=True,
            timeout=30,
            cwd=str(REPO_ROOT),
        )
        for i in range(1, 12):
            assert f"[{i}/12]" in result.stdout, f"Step {i}/12 not found in output"


class TestArchiveStructure:
    """Verify archive step was performed correctly."""

    def test_archive_directory_exists(self):
        """Verify benchmark/archive/ directory exists."""
        assert (REPO_ROOT / "benchmark" / "archive").is_dir()

    def test_archive_contains_runner(self):
        """Verify runner.py is present in archive."""
        assert (REPO_ROOT / "benchmark" / "archive" / "runner.py").exists()

    def test_archive_contains_analyze(self):
        """Verify analyze.py is present in archive."""
        assert (REPO_ROOT / "benchmark" / "archive" / "analyze.py").exists()

    def test_archive_contains_classeval_data(self):
        """Verify ClassEval_data.json is present in archive."""
        assert (REPO_ROOT / "benchmark" / "archive" / "ClassEval_data.json").exists()

    def test_swebench_results_dir_exists(self):
        """Verify benchmark/swebench/results/ directory exists."""
        assert (REPO_ROOT / "benchmark" / "swebench" / "results").is_dir()

    def test_prereqs_not_archived(self):
        """prereqs.sh should remain in benchmark/, not in archive."""
        assert (REPO_ROOT / "benchmark" / "prereqs.sh").exists()
        assert not (REPO_ROOT / "benchmark" / "archive" / "prereqs.sh").exists()
