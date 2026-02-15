# TypeScript Hooks Expansion - Implementation Plan

## Context

The cc-hooks-portable-template provides automated code quality enforcement
via a three-phase PostToolUse hook architecture (auto-format, collect JSON
violations, delegate to subprocess + verify). It currently supports 7
languages (Python, Shell, YAML, JSON, TOML, Dockerfile, Markdown) across
916 lines in `multi_linter.sh`, with 14 automated tests. TypeScript is the
only disabled language (`"typescript": false` in config.json).

The ADR at `docs/adr-typescript-hooks-expansion.md` (17 decisions, 7
resolved questions, ~2000 lines) specifies how to add TypeScript/JS/CSS
support via Biome + Semgrep + session-scoped tools. This plan implements
the **Standard scope**: full Biome pipeline, Semgrep session-scoped
advisory, config fields for opt-in tools (oxlint/tsgo/knip), init script,
pre-commit hooks, and 21 unit tests.

**Excluded from this scope**: oxlint+tsgolint runtime handler logic, tsgo
runtime handler logic, Knip runtime handler logic. Config fields for these
tools are present but handler code is deferred.

---

## Step 0: Discover Biome JSON Reporter Format

**Why first**: The entire Phase 2 violation collection depends on parsing
Biome's `--reporter=json` output. The ADR notes this format is
"experimental and subject to changes in patch releases." The exact
structure must be verified before writing jaq transformations.

**Action**:

1. Create a temp TS file with known violations (unused var, `==` instead
   of `===`)
2. Run `npx @biomejs/biome lint --reporter=json <file>` (or use
   project-local biome if available)
3. Capture and inspect the JSON structure
4. Document the field paths needed: line number, column, rule
   category/code, message, severity
5. Write the jaq transformation based on actual output

**Risk**: If Biome is not installed, install temporarily via
`npx @biomejs/biome@latest` for discovery.

---

## Step 1: Update `config.json` (D12, D13, D14)

**File**: `.claude/hooks/config.json` (58 lines)

**1a** - Replace `"typescript": false` (line 13) with nested object:

```json
"typescript": {
  "enabled": false,
  "js_runtime": "auto",
  "biome_nursery": "warn",
  "biome_unsafe_autofix": false,
  "oxlint_tsgolint": false,
  "tsgo": false,
  "semgrep": true,
  "knip": false
}
```

**1b** - Add 4 entries to `protected_files` (after `"ty.toml"` line 26):

```json
"biome.json",
".oxlintrc.json",
".semgrep.yml",
"knip.json"
```

**1c** - Replace `sonnet_patterns` value (line 47) with expanded pattern
from ADR D12 (adds all Biome + oxlint type-aware rule names).

**Verify**: `jaq '.' .claude/hooks/config.json` succeeds.

---

## Step 2: Update protection fallback defaults (D14)

**2a** - `protect_linter_configs.sh` lines 57-60: Add
`"biome.json" ".oxlintrc.json" ".semgrep.yml" "knip.json"` to the
`printf` fallback list.

**2b** - `stop_config_guardian.sh` lines 45-49: Add same 4 files to the
`PROTECTED_FILES` fallback array.

**Verify**: Run existing `test_hook.sh --self-test` - all 14 tests pass.

---

## Step 3: Add TS config helpers to `multi_linter.sh` (D8, D13)

**File**: `.claude/hooks/multi_linter.sh`
**Insert after**: `is_subprocess_enabled()` (line 76)

Add 3 functions (~60 lines):

### `is_typescript_enabled()`

Handles both `"typescript": false` (legacy) and
`"typescript": {"enabled": true, ...}` (new). Uses jaq to check
`.languages.typescript` type and `.enabled` field.

### `get_ts_config(key, default)`

Reads nested TS config values:
`jaq -r ".languages.typescript.${key} // \"${default}\""`.

### `detect_biome()`

JS runtime auto-detection with session caching (D8):

1. Check `/tmp/.biome_path_${PPID}` cache
2. If `js_runtime` is explicit: use configured runner
3. If `auto`: try `./node_modules/.bin/biome` -> `biome` in PATH ->
   `npx biome` -> `pnpm exec biome` -> `bunx biome`
4. Cache result to `/tmp/.biome_path_${PPID}`

---

## Step 4: Add `handle_typescript()` (D1, D4, D7, D9-D11)

**Insert after**: `rerun_phase2()` function, before first case dispatch.

The function (~150 lines) follows the same three-phase pattern as Python:

### Phase 1: Auto-format (silent)

- Gate: `is_auto_format_enabled`
- Command: `${biome_cmd} check --write [--unsafe] "${fp}"`
- Unsafe flag controlled by `biome_unsafe_autofix` config (D10)

### Phase 2a: Biome lint (blocking)

- Command: `${biome_cmd} lint --reporter=json "${fp}"`
- Parse JSON output via jaq to standard format
  `{line, column, code, message, linter: "biome"}`
- Merge into `collected_violations`

### Phase 2b: Nursery advisory (D9)

- When `biome_nursery: "warn"`: count nursery-prefixed diagnostics
- Emit `[hook:advisory]` count to stderr

### Phase 2c: Semgrep session-scoped (D2, D11)

- Helper: `_handle_semgrep_session(fp)`
- Track files in `/tmp/.semgrep_session_${PPID}`
- After 3+ files: run `semgrep --json --config .semgrep.yml` on all
  modified files, report as `[hook:advisory]`

### Phase 2d: jscpd session-scoped (D17)

- Helper: `_handle_jscpd_session(fp)` - separate from Python's jscpd
  tracking (different session file)

### SFC handling (D4)

- `.vue/.svelte/.astro`: Skip Biome, run Semgrep only
- One-time warning per extension via `/tmp/.sfc_warned_${ext}_${PPID}`

### Nursery mismatch validation (D9)

- Helper: `_validate_nursery_config(biome_cmd)`
- Compare `config.json biome_nursery` vs `biome.json nursery` value
- Emit `[hook:warning]` on mismatch

---

## Step 5: Update case dispatches (D4, D7)

**File**: `.claude/hooks/multi_linter.sh`

**5a** - First case dispatch (file_type assignment, ~line 486):
Add before `*) exit 0`:

```bash
*.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.mts|*.cts|*.css) file_type="typescript" ;;
*.vue|*.svelte|*.astro) file_type="typescript" ;;
```

**5b** - Second case dispatch (handler invocation, ~line 497):
Add before `*) ;;`:

```bash
*.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.mts|*.cts|*.css|*.vue|*.svelte|*.astro)
  handle_typescript "${file_path}"
  ;;
```

---

## Step 6: Update satellite functions (D6, D7)

**6a** - `spawn_fix_subprocess()` format_cmd case (~line 173):
Add `typescript)` case using `detect_biome` for `biome format --write`.

**6b** - `rerun_phase1()` (~line 321):
Add `typescript)` case: `${biome_cmd} check --write [--unsafe]`.

**6c** - `rerun_phase2()` (~line 368):
Add `typescript)` case: parse `biome lint --reporter=json` output, count
error+warning severity diagnostics. Skip advisory tools (Semgrep/tsgo/
Knip) per D11.

**6d** - JSON handler Phase 1 auto-format (D6, ~line 737):
Modify `*.json` case to conditionally use Biome when
`is_typescript_enabled` AND `detect_biome` succeeds. Fallback to jaq
(existing behavior).

**6e** - `rerun_phase1()` JSON case (~line 348):
Same conditional Biome/jaq logic as 6d.

---

## Step 7: Update script header

**File**: `.claude/hooks/multi_linter.sh` lines 3-15

Update `Supports:` comment to include TypeScript/JS/CSS (biome+semgrep).
Update `Optional:` dependencies to include biome, semgrep.

---

## Step 8: Update `.pre-commit-config.yaml` (D15, D17)

**8a** - Insert after `ruff-check` hook (line 20), before `flake8-async`:

```yaml
# === PHASE 1a: TS FORMATTING ===
- id: biome-format
  name: biome (format)
  entry: bash -c 'command -v biome >/dev/null 2>&1 || exit 0; biome format --write "$@"' --
  language: system
  files: \.(jsx?|tsx?|cjs|cts|mjs|mts|css)$

# === PHASE 2a: TS LINTING ===
- id: biome-lint
  name: biome (lint)
  entry: bash -c 'command -v biome >/dev/null 2>&1 || exit 0; biome lint --write "$@"' --
  language: system
  files: \.(jsx?|tsx?|cjs|cts|mjs|mts|css)$
```

**8b** - Update jscpd `files:` pattern (line 101):

```yaml
files: \.(py|sh|yaml|yml|ts|tsx|js|jsx|mjs|cjs|css)$
```

**8c** - Extend INTENTIONAL EXCLUSIONS comment with semgrep, knip,
oxlint+tsgolint, tsgo entries.

---

## Step 9: Update `.jscpd.json` (D17)

Replace `format` array (line 9):

```json
"format": ["python", "bash", "yaml", "typescript", "javascript", "tsx", "jsx", "css"]
```

---

## Step 10: Update `.gitignore` (D16)

Append TS patterns:

```gitignore
# TypeScript / JavaScript
dist/
.next/
.turbo/
*.tsbuildinfo
coverage/
.biome/
```

---

## Step 11: Update `CLAUDE.md` (D14)

Add after `ty.toml` in protected files list:

```text
- `biome.json` - Biome linter/formatter (TypeScript/JS/CSS)
- `.oxlintrc.json` - oxlint configuration
- `.semgrep.yml` - Semgrep security rules
- `knip.json` - Knip dead code detection
```

---

## Step 12: Create `scripts/init-typescript.sh` (D16)

**New file** (~100 lines). Idempotent init script that:

1. Creates `biome.json` from ADR Q2 template (skip if exists)
2. Creates `tsconfig.json` from ADR Q5 template (skip if exists)
3. Creates/merges `package.json` with `@biomejs/biome: "^2.3.0"`
   devDependency (merge via jaq if exists, create minimal if not)
4. Creates `.semgrep.yml` from ADR Q3 template (skip if exists)
5. Updates `config.json` to set `typescript.enabled: true` via jaq
6. Prints next steps (npm install, optional tool installs)

Templates come directly from the ADR resolved questions (Q2, Q3, Q5).

---

## Step 13: Add TypeScript tests to `test_hook.sh` (Q6)

**File**: `.claude/hooks/test_hook.sh`
**Insert**: After model selection tests, before Summary section.

Add a `--- TypeScript Tests ---` section with tests gated on Biome
availability (`command -v biome` or `./node_modules/.bin/biome`).

Tests requiring `typescript.enabled: true` use a temp config directory
with `CLAUDE_PROJECT_DIR` override. Tests requiring disabled TS use the
project's actual config.

**Unit tests** (each uses `HOOK_SKIP_SUBPROCESS=1`):

| # | Test | Expected |
| --- | ------ | -------- |
| 1 | Clean TS file | Exit 0 |
| 2 | TS unused var | Exit 2 |
| 3 | JS file handling | Exit 0 (clean) |
| 4 | JSX with a11y issue | Exit 2 |
| 5 | Config: TS disabled | Exit 0 (skip) |
| 6 | Biome not installed | Exit 0 + warning |
| 7 | Model: simple -> haiku | `[hook:model] haiku` |
| 8 | Model: complex -> sonnet | `[hook:model] sonnet` |
| 9 | Model: volume >5 -> opus | `[hook:model] opus` |
| 10 | JSON via Biome (D6) | Biome formats |
| 11 | Nursery advisory output | `[hook:advisory]` |
| 12 | Protected: biome.json | `{"decision": "block"}` |
| 13 | Pre-commit: format skip | Exit 0 (no Biome) |
| 14 | CSS clean | Exit 0 |
| 15 | CSS violations | Exit 2 |
| 16-21 | Reserved for oxlint/tsgo | Skip with warning |

Tests 16-21 are placeholder skips for deferred handler logic. They
document the expected behavior for when oxlint/tsgo are implemented.

---

## Step 14: Update hooks README

**File**: `.claude/hooks/README.md`

Add TypeScript File Flow Detail section (parallel to Python File Flow
Detail). Document the TS subprocess prompt format. Add Biome to the
linter behavior table.

---

## Verification

After all changes:

1. `jaq '.' .claude/hooks/config.json` - valid JSON
2. `shellcheck .claude/hooks/multi_linter.sh` - no new violations
3. `shellcheck .claude/hooks/protect_linter_configs.sh` - no new
   violations
4. `shellcheck .claude/hooks/stop_config_guardian.sh` - no new violations
5. `shellcheck scripts/init-typescript.sh` - passes
6. `.claude/hooks/test_hook.sh --self-test` - all existing 14 tests pass
   - new TS tests pass
7. Manual: `echo '{"tool_input":{"file_path":"biome.json"}}' | .claude/hooks/protect_linter_configs.sh`
   returns `{"decision": "block", ...}`
8. Manual: Create test TS file, run hook with
   `HOOK_SKIP_SUBPROCESS=1`, verify violations detected
9. `yamllint .pre-commit-config.yaml` - valid YAML

---

## Files Modified Summary

| File | Action | Lines |
| ------ | -------- | ------- |
| `.claude/hooks/multi_linter.sh` | Modify | +315 |
| `.claude/hooks/config.json` | Modify | +20 |
| `.claude/hooks/protect_linter_configs.sh` | Modify | +4 |
| `.claude/hooks/stop_config_guardian.sh` | Modify | +4 |
| `.claude/hooks/test_hook.sh` | Modify | +120 |
| `.claude/hooks/README.md` | Modify | +60 |
| `.pre-commit-config.yaml` | Modify | +22 |
| `.jscpd.json` | Modify | +2 |
| `.gitignore` | Modify | +8 |
| `CLAUDE.md` | Modify | +4 |
| `scripts/init-typescript.sh` | Create | ~100 |
| **Total** | | **~660** |

---

## Execution Strategy

Steps 0-2 first (discovery + config + protection). Run existing tests.
Then Steps 3-7 (core handler). Run tests again. Then Steps 8-14
(pre-commit, init, tests, docs). Final full verification.

Parallelizable: Steps 8-12 are independent and can be done in parallel.
Step 13 (tests) depends on Step 4 (handler). Step 14 (README) is
independent.
