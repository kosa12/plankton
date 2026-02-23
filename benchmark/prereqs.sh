#!/usr/bin/env bash
# Plankton Benchmark — Phase 0 Prerequisites Checker (SWE-bench)
# Verifies all prerequisites from the ADR before SWE-bench benchmark runs.
#
# Usage:
#   bash benchmark/prereqs.sh          # Static checks only (no API calls)
#   bash benchmark/prereqs.sh --full   # All checks including API-calling steps
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PASS=0
FAIL=0
WARN=0
SKIP=0
FULL=false

for arg in "$@"; do
  case "${arg}" in
    --full) FULL=true ;;
    *)
      echo "Unknown argument: ${arg}"
      exit 1
      ;;
  esac
done

pass() {
  printf "  PASS  %s\n" "$1"
  ((PASS++)) || true
}

fail() {
  printf "  FAIL  %s\n" "$1"
  ((FAIL++)) || true
}

warn() {
  printf "  WARN  %s\n" "$1"
  ((WARN++)) || true
}

skip() {
  printf "  SKIP  %s (use --full to run)\n" "$1"
  ((SKIP++)) || true
}

echo "=== Plankton Benchmark Phase 0 Prerequisites (SWE-bench) ==="
echo ""

# --------------------------------------------------------------------------
# Step 1: Claude Code version
# --------------------------------------------------------------------------
echo "[1/12] Claude Code version"
CC_VERSION=$(claude -v 2>/dev/null || echo "not found")
if [[ "${CC_VERSION}" != "not found" ]]; then
  pass "claude -v = ${CC_VERSION}"
else
  fail "claude CLI not found"
fi

# --------------------------------------------------------------------------
# Step 2: cc -bare alias and bare-settings.json
# --------------------------------------------------------------------------
echo "[2/12] cc -bare alias and bare-settings.json"

if grep -q "bare" "${HOME}/.zshrc" 2>/dev/null; then
  pass "cc -bare defined in ~/.zshrc"
else
  fail "cc -bare not found in ~/.zshrc"
fi

BARE_SETTINGS="${HOME}/.claude/bare-settings.json"
if [[ -f "${BARE_SETTINGS}" ]]; then
  if grep -q '"disableAllHooks": true' "${BARE_SETTINGS}"; then
    pass "${BARE_SETTINGS} contains disableAllHooks: true"
  else
    fail "${BARE_SETTINGS} exists but missing disableAllHooks: true"
  fi
else
  fail "${BARE_SETTINGS} not found"
fi

# --------------------------------------------------------------------------
# Step 3: Hooks and linter configs
# --------------------------------------------------------------------------
echo "[3/12] Hooks and linter configs"

HOOKS_DIR="${REPO_ROOT}/.claude/hooks"
hook_count=$(find "${HOOKS_DIR}" -name "*.sh" -type f 2>/dev/null | wc -l | tr -d ' ')
if [[ "${hook_count}" -gt 0 ]]; then
  pass "Found ${hook_count} hook scripts in .claude/hooks/"
else
  fail "No hook scripts found in .claude/hooks/"
fi

if [[ -f "${REPO_ROOT}/.ruff.toml" ]]; then
  pass ".ruff.toml present"
else
  fail ".ruff.toml not found"
fi

if [[ -f "${REPO_ROOT}/ty.toml" ]]; then
  pass "ty.toml present"
else
  fail "ty.toml not found"
fi

# --------------------------------------------------------------------------
# Step 4: Baseline zero hook activity (--full only)
# --------------------------------------------------------------------------
echo "[4/12] Baseline zero hook activity"

if [[ "${FULL}" == true ]]; then
  TASK_DIR=$(mktemp -d)
  cd "${TASK_DIR}" && git init --quiet
  echo "def foo(): pass" >solution.py && git add . && git commit -qm init
  # Source zshrc to get cc function, then run cc -bare
  OUTPUT=$(zsh -c "source ~/.zshrc 2>/dev/null; cc -bare -p --output-format json --dangerously-skip-permissions 'Edit solution.py to add a comment # test'" 2>&1 || true)
  cd "${REPO_ROOT}"
  rm -rf "${TASK_DIR}"
  if echo "${OUTPUT}" | grep -qi "PostToolUse.*hook"; then
    fail "Baseline produced hook activity — cc -bare is not clean"
  else
    pass "Baseline produces zero hook activity"
  fi
else
  skip "Baseline hook isolation"
fi

# --------------------------------------------------------------------------
# Step 5: CLAUDE.md status
# --------------------------------------------------------------------------
echo "[5/12] CLAUDE.md status"

if [[ -f "${REPO_ROOT}/CLAUDE.md.bak" ]] && [[ ! -f "${REPO_ROOT}/CLAUDE.md" ]]; then
  pass "CLAUDE.md renamed to CLAUDE.md.bak"
elif [[ -f "${REPO_ROOT}/CLAUDE.md" ]]; then
  fail "CLAUDE.md still present — rename to CLAUDE.md.bak before benchmark runs"
else
  fail "Neither CLAUDE.md nor CLAUDE.md.bak found"
fi

# --------------------------------------------------------------------------
# Step 6: claude -p subprocess behavior (--full only)
# --------------------------------------------------------------------------
echo "[6/12] claude -p subprocess behavior"

if [[ "${FULL}" == true ]]; then
  # Bug 1: TTY hang workaround
  TTY_OUTPUT=$(echo "say hi" | timeout 30 script -q /dev/null claude -p "say hi" 2>&1 || true)
  if [[ -n "${TTY_OUTPUT}" ]]; then
    pass "TTY hang workaround works (script -q)"
  else
    fail "TTY hang workaround failed — claude -p produced empty output via script"
  fi

  # Bug 2: Large stdin
  LARGE_PROMPT=$(python3 -c "print('Edit solution.py to add a comment. ' * 500)")
  STDIN_DIR=$(mktemp -d)
  cd "${STDIN_DIR}" && git init --quiet
  echo "def foo(): pass" >solution.py && git add . && git commit -qm init
  echo "${LARGE_PROMPT}" >prompt.txt
  STDIN_OUTPUT=$(timeout 60 claude -p --dangerously-skip-permissions <prompt.txt 2>&1 || true)
  cd "${REPO_ROOT}"
  rm -rf "${STDIN_DIR}"
  if [[ -n "${STDIN_OUTPUT}" ]]; then
    pass "Large stdin (>7K chars) produces non-empty output"
  else
    fail "Large stdin produced empty output — use file-based prompt workaround"
  fi
else
  skip "claude -p subprocess behavior (TTY hang + large stdin)"
fi

# --------------------------------------------------------------------------
# Step 7: Evaluation harness installation
# --------------------------------------------------------------------------
echo "[7/12] Evaluation harness"

HAL_OK=false
SB_OK=false

if command -v hal-eval >/dev/null 2>&1; then
  pass "hal-eval (HAL harness) installed"
  HAL_OK=true
fi

if command -v sb >/dev/null 2>&1; then
  pass "sb (sb-cli) installed"
  SB_OK=true
fi

if [[ "${HAL_OK}" == false ]] && [[ "${SB_OK}" == false ]]; then
  warn "Neither hal-eval nor sb-cli installed — install one before benchmark runs"
fi

# --------------------------------------------------------------------------
# Step 8: Subprocess permission fix
# --------------------------------------------------------------------------
echo "[8/12] Subprocess permission fix"

ML_SCRIPT="${REPO_ROOT}/.claude/hooks/multi_linter.sh"
if [[ -f "${ML_SCRIPT}" ]]; then
  if grep -q 'dangerously-skip-permissions' "${ML_SCRIPT}"; then
    pass "multi_linter.sh contains --dangerously-skip-permissions"
  else
    fail "multi_linter.sh missing --dangerously-skip-permissions"
  fi

  if grep -q 'disallowedTools' "${ML_SCRIPT}"; then
    pass "multi_linter.sh contains --disallowedTools"
  else
    fail "multi_linter.sh missing --disallowedTools"
  fi
else
  fail "multi_linter.sh not found"
fi

SUB_SETTINGS="${REPO_ROOT}/.claude/subprocess-settings.json"
if [[ -f "${SUB_SETTINGS}" ]]; then
  pass "subprocess-settings.json present"
else
  fail "subprocess-settings.json not found"
fi

# --------------------------------------------------------------------------
# Step 9: Tool restriction enforcement (--full only)
# --------------------------------------------------------------------------
echo "[9/12] Tool restriction enforcement"

if [[ "${FULL}" == true ]]; then
  TASK_DIR=$(mktemp -d)
  cd "${TASK_DIR}" && git init --quiet
  echo "def foo(): pass" >solution.py && git add . && git commit -qm init
  TOOL_OUTPUT=$(timeout 60 claude -p --output-format json --dangerously-skip-permissions \
    --disallowedTools WebFetch,WebSearch,Task \
    "Try to use WebSearch to find something, then edit solution.py to add a comment" 2>&1 || true)
  cd "${REPO_ROOT}"
  rm -rf "${TASK_DIR}"
  if echo "${TOOL_OUTPUT}" | grep -q '"tool_name":"WebSearch"'; then
    fail "WebSearch was invoked despite --disallowedTools"
  else
    pass "Tool restriction enforced (no WebSearch in output)"
  fi
else
  skip "Tool restriction enforcement"
fi

# --------------------------------------------------------------------------
# Step 10: Concurrency probe (--full only)
# --------------------------------------------------------------------------
echo "[10/12] Concurrency probe"

if [[ "${FULL}" == true ]]; then
  echo "  Running escalating concurrency test..."
  BEST_N=1
  for N in 1 2 4 8; do
    START=$(date +%s)
    PIDS=()
    for _i in $(seq 1 "${N}"); do
      TASK_DIR=$(mktemp -d)
      (
        cd "${TASK_DIR}" && git init --quiet
        echo "def foo(): pass" >solution.py && git add . && git commit -qm init
        timeout 60 claude -p --output-format json --dangerously-skip-permissions \
          "Edit solution.py to add a docstring to foo" >/dev/null 2>&1
        rm -rf "${TASK_DIR}"
      ) &
      PIDS+=($!)
    done
    FAILED=0
    for pid in "${PIDS[@]}"; do
      wait "${pid}" || ((FAILED++)) || true
    done
    END=$(date +%s)
    ELAPSED=$((END - START))
    printf "    N=%d: %ds elapsed, %d failures\n" "${N}" "${ELAPSED}" "${FAILED}"
    if [[ "${FAILED}" -eq 0 ]]; then
      BEST_N=${N}
    else
      break
    fi
  done
  pass "Concurrency probe complete — max safe N=${BEST_N}"
else
  skip "Concurrency probe"
fi

# --------------------------------------------------------------------------
# Step 11: Archive verification
# --------------------------------------------------------------------------
echo "[11/12] Archive verification"

if [[ -d "${SCRIPT_DIR}/archive" ]]; then
  pass "benchmark/archive/ exists"
else
  fail "benchmark/archive/ not found — run archive step first"
fi

if [[ -d "${SCRIPT_DIR}/swebench/results" ]]; then
  pass "benchmark/swebench/results/ exists"
else
  fail "benchmark/swebench/results/ not found"
fi

# --------------------------------------------------------------------------
# Step 12: Summary
# --------------------------------------------------------------------------
echo ""
echo "=== Prerequisites Checklist ==="
echo ""
CC_CHECK=" "
if [[ "${CC_VERSION}" != "not found" ]]; then CC_CHECK="x"; fi
echo "  [${CC_CHECK}] Claude Code version recorded (${CC_VERSION})"
echo "  [ ] cc -bare alias loads and expands correctly"
echo "  [ ] ~/.claude/bare-settings.json contains disableAllHooks: true"
echo "  [ ] .claude/hooks/ and linter configs present"
echo "  [ ] Baseline (cc -bare -p) produces zero hook activity"
echo "  [ ] CLAUDE.md renamed to CLAUDE.md.bak"
echo "  [ ] TTY hang workaround verified"
echo "  [ ] Large stdin workaround verified (>7K chars)"
echo "  [ ] Tool restriction enforced: --disallowedTools WebFetch,WebSearch,Task"
echo "  [ ] HAL harness (or sb-cli) installed"
echo "  [ ] Concurrency probe completed"
echo "  [ ] Subprocess permission fix verified"
echo "  [ ] Previous benchmark infrastructure archived"
echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed, ${WARN} warnings, ${SKIP} skipped ==="

if [[ ${FAIL} -gt 0 ]]; then
  echo "Fix failures before running the benchmark."
  exit 1
else
  echo "All prerequisites met. Ready for Phase 2."
fi
