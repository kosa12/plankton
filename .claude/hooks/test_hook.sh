#!/bin/bash
# test_hook.sh - Test multi_linter.sh with sample input
#
# Usage: ./test_hook.sh <file_path>
#        ./test_hook.sh --self-test
#
# Simulates the JSON input that Claude Code sends to PostToolUse hooks
# Useful for debugging hook behavior without running Claude Code

set -euo pipefail

script_dir="$(dirname "$(realpath "$0" || true)")"
project_dir="$(dirname "$(dirname "${script_dir}")")"

# Self-test mode: comprehensive automated testing
run_self_test() {
  local passed=0
  local failed=0
  local temp_dir
  temp_dir=$(mktemp -d)
  trap 'rm -rf "${temp_dir}"; rm -f /tmp/.biome_path_$$ /tmp/.semgrep_session_$$ /tmp/.semgrep_session_$$.done /tmp/.jscpd_ts_session_$$ /tmp/.jscpd_session_$$ /tmp/.sfc_warned_*_$$ /tmp/.nursery_checked_$$' EXIT

  echo "=== Hook Self-Test Suite ==="
  echo ""

  # Test helper for temp files (creates file with content)
  # Uses HOOK_SKIP_SUBPROCESS=1 to test detection without subprocess fixing
  test_temp_file() {
    local name="$1"
    local file="$2"
    local content="$3"
    local expect_exit="$4"

    echo "${content}" >"${file}"
    local json_input='{"tool_input": {"file_path": "'"${file}"'"}}'
    set +e
    echo "${json_input}" | HOOK_SKIP_SUBPROCESS=1 "${script_dir}/multi_linter.sh" >/dev/null 2>&1
    local actual_exit=$?
    set -e

    if [[ "${actual_exit}" -eq "${expect_exit}" ]]; then
      echo "PASS ${name}: exit ${actual_exit} (expected ${expect_exit})"
      passed=$((passed + 1))
    else
      echo "FAIL ${name}: exit ${actual_exit} (expected ${expect_exit})"
      failed=$((failed + 1))
    fi
  }

  # Test helper for existing files (does NOT modify file)
  # Uses HOOK_SKIP_SUBPROCESS=1 to test detection without subprocess fixing
  test_existing_file() {
    local name="$1"
    local file="$2"
    local expect_exit="$3"

    local json_input='{"tool_input": {"file_path": "'"${file}"'"}}'
    set +e
    echo "${json_input}" | HOOK_SKIP_SUBPROCESS=1 "${script_dir}/multi_linter.sh" >/dev/null 2>&1
    local actual_exit=$?
    set -e

    if [[ "${actual_exit}" -eq "${expect_exit}" ]]; then
      echo "PASS ${name}: exit ${actual_exit} (expected ${expect_exit})"
      passed=$((passed + 1))
    else
      echo "FAIL ${name}: exit ${actual_exit} (expected ${expect_exit})"
      failed=$((failed + 1))
    fi
  }

  # Dockerfile pattern tests
  echo "--- Dockerfile Pattern Coverage ---"
  test_temp_file "Dockerfile (valid)" \
    "${temp_dir}/Dockerfile" \
    'FROM python:3.11-slim
LABEL maintainer="test" version="1.0"
CMD ["python"]' 0

  test_temp_file "*.dockerfile (valid)" \
    "${temp_dir}/test.dockerfile" \
    'FROM alpine:3.19
LABEL maintainer="test" version="1.0"
CMD ["echo"]' 0

  test_temp_file "*.dockerfile (invalid - missing labels)" \
    "${temp_dir}/bad.dockerfile" \
    'FROM ubuntu
RUN apt-get update' 2

  # Other file type tests
  echo ""
  echo "--- Other File Types ---"
  # Python needs proper docstrings now that D rules are enabled
  test_temp_file "Python (valid)" \
    "${temp_dir}/test.py" \
    '"""Module docstring."""


def foo():
    """Do nothing."""
    pass' 0

  test_temp_file "Shell (valid)" \
    "${temp_dir}/test.sh" \
    '#!/bin/bash
echo "hello"' 0

  test_temp_file "JSON (valid)" \
    "${temp_dir}/test.json" \
    '{"key": "value"}' 0

  test_temp_file "JSON (invalid syntax)" \
    "${temp_dir}/bad.json" \
    '{invalid}' 2

  test_temp_file "YAML (valid)" \
    "${temp_dir}/test.yaml" \
    'key: value' 0

  # Styled output format tests
  # Uses HOOK_SKIP_SUBPROCESS=1 to capture output without subprocess
  echo ""
  echo "--- Styled Output Format Tests ---"

  test_output_format() {
    local name="$1"
    local file="$2"
    local content="$3"
    local pattern="$4"

    echo "${content}" >"${file}"
    local json_input='{"tool_input": {"file_path": "'"${file}"'"}}'
    set +e
    local output
    output=$(echo "${json_input}" | HOOK_SKIP_SUBPROCESS=1 "${script_dir}/multi_linter.sh" 2>&1)
    set -e

    if echo "${output}" | grep -qE "${pattern}"; then
      echo "PASS ${name}: pattern '${pattern}' found"
      passed=$((passed + 1))
    else
      echo "FAIL ${name}: pattern '${pattern}' NOT found"
      echo "   Output: ${output}"
      failed=$((failed + 1))
    fi
  }

  # Test violations output contains JSON_SYNTAX code
  test_output_format "JSON violations output" \
    "${temp_dir}/marked.json" \
    '{invalid}' \
    'JSON_SYNTAX'

  # Test Dockerfile violations are captured
  test_output_format "Dockerfile violations captured" \
    "${temp_dir}/blend.dockerfile" \
    'FROM ubuntu
RUN apt-get update' \
    'DL[0-9]+'

  # Model selection tests (new three-phase architecture)
  echo ""
  echo "--- Model Selection Tests ---"

  test_model_selection() {
    local name="$1"
    local file="$2"
    local content="$3"
    local expect_model="$4"

    echo "${content}" >"${file}"
    local json_input='{"tool_input": {"file_path": "'"${file}"'"}}'
    set +e
    local output
    output=$(echo "${json_input}" | HOOK_SKIP_SUBPROCESS=1 HOOK_DEBUG_MODEL=1 "${script_dir}/multi_linter.sh" 2>&1)
    set -e

    local actual_model
    actual_model=$(echo "${output}" | grep -oE '\[hook:model\] (haiku|sonnet|opus)' | awk '{print $2}' || echo "none")

    if [[ "${actual_model}" == "${expect_model}" ]]; then
      echo "PASS ${name}: model=${actual_model} (expected ${expect_model})"
      passed=$((passed + 1))
    else
      echo "FAIL ${name}: model=${actual_model} (expected ${expect_model})"
      failed=$((failed + 1))
    fi
  }

  # Simple violation -> haiku (needs docstrings to avoid D rules triggering sonnet)
  test_model_selection "Simple (F841) -> haiku" \
    "${temp_dir}/simple.py" \
    '"""Module docstring."""


def foo():
    """Do nothing."""
    unused = 1
    return 42' \
    "haiku"

  # Complexity violation -> sonnet (PLR0913 too many args, <=5 total violations)
  test_model_selection "Complexity (PLR0913) -> sonnet" \
    "${temp_dir}/complex.py" \
    '"""Module docstring."""


def process(one, two, three, four, five, six):
    """Process with too many args."""
    return one + two + three + four + five + six' \
    "sonnet"

  # >5 violations -> opus (needs docstrings, 6 F841 unused variables)
  test_model_selection ">5 violations -> opus" \
    "${temp_dir}/many.py" \
    '"""Module docstring."""


def foo():
    """Create unused variables."""
    a = 1
    b = 2
    c = 3
    d = 4
    e = 5
    f = 6
    return 42' \
    "opus"

  # Docstring violation -> sonnet
  test_model_selection "Docstring (D103) -> sonnet" \
    "${temp_dir}/nodoc.py" \
    'def missing_docstring():
    return 42' \
    "sonnet"

  # TypeScript tests (gated on Biome availability)
  echo ""
  echo "--- TypeScript Tests ---"

  # Create a temp project directory with TS-enabled config
  ts_project_dir="${temp_dir}/ts_project"
  mkdir -p "${ts_project_dir}/.claude/hooks"
  cat > "${ts_project_dir}/.claude/hooks/config.json" << 'TS_CFG_EOF'
{
  "languages": {
    "python": true, "shell": true, "yaml": true, "json": true,
    "toml": true, "dockerfile": true, "markdown": true,
    "typescript": {
      "enabled": true, "js_runtime": "auto", "biome_nursery": "warn",
      "biome_unsafe_autofix": false, "semgrep": false, "knip": false
    }
  },
  "phases": { "auto_format": true, "subprocess_delegation": true },
  "subprocess": {
    "timeout": 300,
    "model_selection": {
      "sonnet_patterns": "C901|PLR[0-9]+|complexity|useExhaustiveDependencies|noExplicitAny",
      "opus_patterns": "unresolved-attribute|type-assertion",
      "volume_threshold": 5
    }
  }
}
TS_CFG_EOF

  # Helper: run TS test with TS-enabled config
  test_ts_file() {
    local name="$1"
    local file="$2"
    local content="$3"
    local expect_exit="$4"

    echo "${content}" >"${file}"
    local json_input='{"tool_input": {"file_path": "'"${file}"'"}}'
    set +e
    echo "${json_input}" | HOOK_SKIP_SUBPROCESS=1 \
      CLAUDE_PROJECT_DIR="${ts_project_dir}" \
      "${script_dir}/multi_linter.sh" >/dev/null 2>&1
    local actual_exit=$?
    set -e

    if [[ "${actual_exit}" -eq "${expect_exit}" ]]; then
      echo "PASS ${name}: exit ${actual_exit} (expected ${expect_exit})"
      passed=$((passed + 1))
    else
      echo "FAIL ${name}: exit ${actual_exit} (expected ${expect_exit})"
      failed=$((failed + 1))
    fi
  }

  # Helper: run TS test and check stderr output
  test_ts_output() {
    local name="$1"
    local file="$2"
    local content="$3"
    local pattern="$4"

    echo "${content}" >"${file}"
    local json_input='{"tool_input": {"file_path": "'"${file}"'"}}'
    set +e
    local output
    output=$(echo "${json_input}" | HOOK_SKIP_SUBPROCESS=1 \
      CLAUDE_PROJECT_DIR="${ts_project_dir}" \
      "${script_dir}/multi_linter.sh" 2>&1)
    set -e

    if echo "${output}" | grep -qE "${pattern}"; then
      echo "PASS ${name}: pattern '${pattern}' found"
      passed=$((passed + 1))
    else
      echo "FAIL ${name}: pattern '${pattern}' NOT found"
      echo "   Output: ${output}"
      failed=$((failed + 1))
    fi
  }

  # Detect Biome for gating
  biome_cmd=""
  if [[ -x "${project_dir}/node_modules/.bin/biome" ]]; then
    biome_cmd="${project_dir}/node_modules/.bin/biome"
  elif command -v biome >/dev/null 2>&1; then
    biome_cmd="biome"
  fi

  if [[ -n "${biome_cmd}" ]]; then
    # Test 1: Clean TS file -> exit 0
    test_ts_file "TS clean file" \
      "${temp_dir}/clean.ts" \
      'const greeting: string = "hello";
console.log(greeting);' 0

    # Test 2: TS unused var -> exit 2
    test_ts_file "TS unused variable" \
      "${temp_dir}/unused.ts" \
      'const used = "hello";
const unused = "world";
console.log(used);' 2

    # Test 3: JS file handling -> exit 0
    test_ts_file "JS clean file" \
      "${temp_dir}/clean.js" \
      'const x = 1;
console.log(x);' 0

    # Test 4: JSX with a11y issue -> exit 2
    test_ts_file "JSX a11y violation" \
      "${temp_dir}/bad.jsx" \
      'function App() {
  return <img src="photo.jpg" />;
}' 2

    # Test 5: Config: TS disabled -> exit 0 (skip)
    test_temp_file "TS disabled skips" \
      "${temp_dir}/skipped.ts" \
      'const unused = "should be skipped";' 0

    # Test 6: CSS clean -> exit 0
    test_ts_file "CSS clean file" \
      "${temp_dir}/clean.css" \
      'body {
  margin: 0;
  padding: 0;
}' 0

    # Test 7: CSS violations -> exit 2
    test_ts_file "CSS violation" \
      "${temp_dir}/bad.css" \
      'a { colr: red; }' 2

    # Test 8: Biome violations output contains category
    test_ts_output "TS violations output" \
      "${temp_dir}/output.ts" \
      'const used = 1;
const unused = 2;
console.log(used);' \
      'biome'

    # Test 9: Nursery advisory output
    # Nursery rules require biome.json in project root with explicit
    # nursery config; default biome config has no lint/nursery/ rules.
    # Conditionally test if a nursery rule fires on the fixture.
    echo "${temp_dir}/nursery.ts" > /dev/null  # placeholder path
    local nursery_file="${temp_dir}/nursery.ts"
    printf 'const foo = "bar";\nfunction f() { const foo = 1; console.log(foo); }\nf();\nconsole.log(foo);\n' > "${nursery_file}"
    local nursery_json='{"tool_input": {"file_path": "'"${nursery_file}"'"}}'
    set +e
    local nursery_out
    nursery_out=$(echo "${nursery_json}" | HOOK_SKIP_SUBPROCESS=1 \
      CLAUDE_PROJECT_DIR="${ts_project_dir}" \
      "${script_dir}/multi_linter.sh" 2>&1)
    set -e
    if echo "${nursery_out}" | grep -qE 'hook:advisory'; then
      echo "PASS TS nursery advisory: pattern 'hook:advisory' found"
      passed=$((passed + 1))
    else
      echo "[skip] #9 TS nursery advisory (no nursery rules in default biome config)"
    fi

    # Test 10: Protected biome.json
    echo ""
    echo "--- TypeScript Protection Tests ---"
    local biome_protect_result
    biome_protect_result=$(echo '{"tool_input":{"file_path":"biome.json"}}' \
      | CLAUDE_PROJECT_DIR="${ts_project_dir}" \
        "${script_dir}/protect_linter_configs.sh" 2>/dev/null)
    if echo "${biome_protect_result}" | grep -q '"block"'; then
      echo "PASS Protected: biome.json blocked"
      passed=$((passed + 1))
    else
      echo "FAIL Protected: biome.json not blocked"
      echo "   Output: ${biome_protect_result}"
      failed=$((failed + 1))
    fi

    # Test 11: Model selection for TS - simple -> haiku
    echo ""
    echo "--- TypeScript Model Selection Tests ---"

    test_ts_model() {
      local name="$1"
      local file="$2"
      local content="$3"
      local expect_model="$4"

      echo "${content}" >"${file}"
      local json_input='{"tool_input": {"file_path": "'"${file}"'"}}'
      set +e
      local output
      output=$(echo "${json_input}" | HOOK_SKIP_SUBPROCESS=1 HOOK_DEBUG_MODEL=1 \
        CLAUDE_PROJECT_DIR="${ts_project_dir}" \
        "${script_dir}/multi_linter.sh" 2>&1)
      set -e

      local actual_model
      actual_model=$(echo "${output}" | grep -oE '\[hook:model\] (haiku|sonnet|opus)' \
        | awk '{print $2}' || echo "none")

      if [[ "${actual_model}" == "${expect_model}" ]]; then
        echo "PASS ${name}: model=${actual_model} (expected ${expect_model})"
        passed=$((passed + 1))
      else
        echo "FAIL ${name}: model=${actual_model} (expected ${expect_model})"
        failed=$((failed + 1))
      fi
    }

    test_ts_model "TS simple -> haiku" \
      "${temp_dir}/ts_simple.ts" \
      'const used = 1;
const unused = 2;
console.log(used);' \
      "haiku"

    # Test 12: Model selection for TS - sonnet (type-aware rule)
    test_ts_model "TS type-aware -> sonnet" \
      "${temp_dir}/ts_sonnet.ts" \
      'const x: any = 1;
console.log(x);' \
      "sonnet"

    # Test 13: Model selection for TS - >5 violations -> opus
    test_ts_model "TS >5 violations -> opus" \
      "${temp_dir}/ts_many.ts" \
      'const a = 1;
const b = 2;
const c = 3;
const d = 4;
const e = 5;
const f = 6;
console.log("none used");' \
      "opus"

    # Test 14: JSON via Biome when TS enabled (D6)
    test_ts_file "JSON via Biome (D6)" \
      "${temp_dir}/biome_json.json" \
      '{"key": "value"}' 0

    # Test 15: SFC file warning (D4)
    if ! command -v semgrep >/dev/null 2>&1; then
      local sfc_file="${temp_dir}/component.vue"
      printf '<script>export default {}</script>\n' > "${sfc_file}"
      local sfc_json='{"tool_input":{"file_path":"'"${sfc_file}"'"}}'
      set +e
      local sfc_out
      sfc_out=$(echo "${sfc_json}" | HOOK_SKIP_SUBPROCESS=1 \
        CLAUDE_PROJECT_DIR="${ts_project_dir}" \
        "${script_dir}/multi_linter.sh" 2>&1)
      set -e
      if echo "${sfc_out}" | grep -q 'hook:warning'; then
        echo "PASS SFC warning for .vue"
        passed=$((passed + 1))
      else
        echo "FAIL SFC warning for .vue"
        echo "   Output: ${sfc_out}"
        failed=$((failed + 1))
      fi
    else
      echo "[skip] #15 SFC warning (semgrep installed)"
    fi

    # Test 16: D3 oxlint overlap — nursery rules actually skipped
    local d3_dir="${temp_dir}/d3_project"
    mkdir -p "${d3_dir}/.claude/hooks"
    cat > "${d3_dir}/.claude/hooks/config.json" << 'D3_CFG_EOF'
{
  "languages": {
    "typescript": {
      "enabled": true, "oxlint_tsgolint": true,
      "biome_nursery": "warn", "semgrep": false
    }
  },
  "phases": {"auto_format": true, "subprocess_delegation": true},
  "subprocess": {"timeout": 300, "model_selection": {
    "sonnet_patterns": "C901", "opus_patterns": "x",
    "volume_threshold": 5
  }}
}
D3_CFG_EOF
    # biome.json enables the nursery rule so it would fire without --skip
    cat > "${d3_dir}/biome.json" << 'D3_BIOME_EOF'
{
  "linter": {
    "rules": {
      "nursery": {
        "noFloatingPromises": "error"
      }
    }
  }
}
D3_BIOME_EOF
    # tsconfig.json required for type-aware nursery rules
    cat > "${d3_dir}/tsconfig.json" << 'D3_TS_EOF'
{
  "compilerOptions": {
    "strict": true,
    "target": "es2020",
    "module": "es2020",
    "moduleResolution": "bundler"
  },
  "include": ["*.ts"]
}
D3_TS_EOF
    # File with floating promise (triggers noFloatingPromises)
    local d3_file="${d3_dir}/d3_test.ts"
    cat > "${d3_file}" << 'D3_SRC_EOF'
async function fetchData(): Promise<string> {
  return "data";
}
fetchData();
const unused = 1;
console.log("test");
D3_SRC_EOF
    local d3_json='{"tool_input":{"file_path":"'"${d3_file}"'"}}'
    set +e
    local d3_out
    d3_out=$(echo "${d3_json}" | HOOK_SKIP_SUBPROCESS=1 \
      CLAUDE_PROJECT_DIR="${d3_dir}" \
      "${script_dir}/multi_linter.sh" 2>&1)
    set -e
    # With oxlint_tsgolint=true, --skip suppresses the 3 overlap rules
    # Match lint violation format (lint/nursery/...) not config warnings
    if echo "${d3_out}" | grep -qE \
        'lint/nursery/noFloatingPromises|lint/nursery/noMisusedPromises|lint/nursery/useAwaitThenable'; then
      echo "FAIL D3 overlap: disabled rules still reported"
      echo "   Output: ${d3_out}"
      failed=$((failed + 1))
    else
      echo "PASS D3 overlap: nursery rules skipped"
      passed=$((passed + 1))
    fi

  else
    echo "[skip] Biome not installed - skipping TypeScript tests"
    echo "       Install: npm i -D @biomejs/biome"
  fi

  # Fallback: Biome not installed -> exit 0 + warning
  echo ""
  echo "--- TypeScript Fallback Tests ---"
  # Create a config that forces a non-existent biome path
  no_biome_dir="${temp_dir}/no_biome_project"
  mkdir -p "${no_biome_dir}/.claude/hooks"
  # Use js_runtime: "none" to force detect_biome() to find nothing
  cat > "${no_biome_dir}/.claude/hooks/config.json" << 'NOBIOME_EOF'
{
  "languages": {
    "typescript": {
      "enabled": true, "js_runtime": "none", "semgrep": false
    }
  },
  "phases": { "auto_format": true, "subprocess_delegation": true },
  "subprocess": { "timeout": 300, "model_selection": {
    "sonnet_patterns": "C901", "opus_patterns": "unresolved-attribute",
    "volume_threshold": 5
  }}
}
NOBIOME_EOF

  no_biome_content='const x = 1;
console.log(x);'
  echo "${no_biome_content}" > "${temp_dir}/no_biome.ts"
  no_biome_json='{"tool_input": {"file_path": "'"${temp_dir}/no_biome.ts"'"}}'
  set +e
  echo "${no_biome_json}" | HOOK_SKIP_SUBPROCESS=1 \
    CLAUDE_PROJECT_DIR="${no_biome_dir}" \
    "${script_dir}/multi_linter.sh" >/dev/null 2>&1
  no_biome_exit=$?
  set -e

  if [[ "${no_biome_exit}" -eq 0 ]]; then
    echo "PASS Biome not installed -> exit 0"
    passed=$((passed + 1))
  else
    echo "FAIL Biome not installed -> exit ${no_biome_exit} (expected 0)"
    failed=$((failed + 1))
  fi

  # Tests 17-21: Deferred tool tests (ADR Q6)
  echo ""
  echo "--- Deferred Tool Tests (placeholders) ---"
  echo "[skip] #17 oxlint: type-aware violation (deferred)"
  echo "[skip] #18 oxlint: disabled default (deferred)"
  echo "[skip] #19 oxlint: timeout gate (deferred)"
  echo "[skip] #20 tsgo: session advisory (deferred)"
  echo "[skip] #21 tsgo: disabled default (deferred)"

  # Summary
  echo ""
  echo "=== Summary ==="
  echo "Passed: ${passed}"
  echo "Failed: ${failed}"

  if [[ "${failed}" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

file_path="${1:-}"

if [[ "${file_path}" == "--self-test" ]]; then
  run_self_test
fi

if [[ -z "${file_path}" ]]; then
  echo "Usage: $0 <file_path>"
  echo "       $0 --self-test    # Run comprehensive test suite"
  echo ""
  echo "Examples:"
  echo "  $0 ./my_script.sh      # Test shell linting"
  echo "  $0 ./config.yaml       # Test YAML linting"
  echo "  $0 ./main.py           # Test Python complexity"
  echo "  $0 ./Dockerfile        # Test Dockerfile linting"
  echo "  $0 ./app.dockerfile    # Test *.dockerfile extension"
  echo ""
  echo "Exit codes:"
  echo "  0 - No issues or warnings only (not fed to Claude)"
  echo "  2 - Blocking errors found (fed to Claude via stderr)"
  exit 1
fi

if [[ ! -f "${file_path}" ]]; then
  echo "Error: File not found: ${file_path}"
  exit 1
fi

# Construct JSON input like Claude Code does
json_input=$(
  cat <<EOF
{
  "tool_name": "Write",
  "tool_input": {
    "file_path": "$(realpath "${file_path}" || true)"
  }
}
EOF
)

echo "=== Testing multi_linter.sh ==="
echo "Input file: ${file_path}"
echo "JSON input: ${json_input}"
echo ""
echo "=== Hook Output ==="

# Run the hook and capture exit code
script_dir="$(dirname "$(realpath "$0" || true)")"
set +e
echo "${json_input}" | "${script_dir}/multi_linter.sh"
exit_code=$?
set -e

echo ""
echo "=== Result ==="
echo "Exit code: ${exit_code}"
case ${exit_code} in
  0) echo "Status: OK (warnings only, not fed to Claude)" ;;
  2) echo "Status: BLOCKING (errors found, fed to Claude)" ;;
  *) echo "Status: UNKNOWN (exit code ${exit_code})" ;;
esac
