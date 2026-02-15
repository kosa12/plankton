│ Plan to implement                                                                                                                     │
│                                                                                                                                       │
│ Audit Remediation Plan                                                                                                                │
│                                                                                                                                       │
│ Context                                                                                                                               │
│                                                                                                                                       │
│ The TypeScript Hooks Expansion (Steps 0-14) is implemented and passing                                                                │
│ all 15 self-tests. A post-implementation audit identified 3 actionable                                                                │
│ issues: a correctness deviation from the ADR, linting violations in new                                                               │
│ README content, and missing test coverage vs ADR spec. This plan fixes                                                                │
│ all three.                                                                                                                            │
│                                                                                                                                       │
│ Reference docs:                                                                                                                       │
│ - ADR: docs/adr-typescript-hooks-expansion.md                                                                                         │
│ - Original plan: docs/adr-implementation-plans/TypeScript Hooks Expansion - Implementation Plan.md                                    │
│                                                                                                                                       │
│ ---                                                                                                                                   │
│ Fix 1: CSS + Semgrep guard (ADR D4 deviation)                                                                                         │
│                                                                                                                                       │
│ File: .claude/hooks/multi_linter.sh line 787                                                                                          │
│                                                                                                                                       │
│ Problem: ADR line 353 states .css files are "Biome only — Semgrep                                                                     │
│ not applicable for CSS." The current code passes CSS files to                                                                         │
│ _handle_semgrep_session(), which incorrectly counts them toward the                                                                   │
│ 3-file Semgrep trigger threshold and includes them in Semgrep scans.                                                                  │
│                                                                                                                                       │
│ Change: Replace line 787:                                                                                                             │
│                                                                                                                                       │
│ # Before                                                                                                                              │
│   _handle_semgrep_session "${fp}"                                                                                                     │
│                                                                                                                                       │
│ # After                                                                                                                               │
│   [[ "${ext}" != "css" ]] && _handle_semgrep_session "${fp}"                                                                          │
│                                                                                                                                       │
│ The ext variable is already in scope (set at line 698). jscpd at                                                                      │
│ line 790 stays unchanged — ADR D17 explicitly includes CSS in jscpd                                                                   │
│ coverage.                                                                                                                             │
│                                                                                                                                       │
│ ---                                                                                                                                   │
│ Fix 2: README.md MD013 line-length violations                                                                                         │
│                                                                                                                                       │
│ File: .claude/hooks/README.md lines 861-875                                                                                           │
│                                                                                                                                       │
│ Problem: 9 lines in the Configuration Options table exceed the                                                                        │
│ 80-character limit set in .markdownlint.jsonc. These are all in                                                                       │
│ content added during Step 14.                                                                                                         │
│                                                                                                                                       │
│ Approach: Shorten the table by abbreviating column content. The                                                                       │
│ Key column uses the longest strings (languages.typescript.*).                                                                         │
│ Use shorter abbreviations in Purpose and compact Type/Default.                                                                        │
│                                                                                                                                       │
│ Target: every row under 80 characters. Specific shortenings:                                                                          │
│ - languages.typescript -> languages.typescript (keep, 22 chars)                                                                       │
│ - languages.typescript.enabled -> …typescript.enabled (keep)                                                                          │
│ - "TypeScript/JS/CSS config" -> "TS/JS/CSS config"                                                                                    │
│ - "Enable TS/JS/CSS linting" -> "Enable TS/JS/CSS"                                                                                    │
│ - "JS runtime: auto/node/bun/pnpm" -> "auto/node/bun/pnpm"                                                                            │
│ - "Nursery rules: off/warn/error" -> "off/warn/error"                                                                                 │
│ - "Enable Semgrep session scanning" -> "Semgrep session scan"                                                                         │
│ - "Files protected from modification" -> "Protected from edits"                                                                       │
│ - "Paths excluded from security linters" -> "Security lint exclusions"                                                                │
│ - "Enable/disable Phase 1 auto-formatting" -> "Phase 1 auto-format"                                                                   │
│ - "Enable/disable Phase 3 subprocess" -> "Phase 3 subprocess"                                                                         │
│ - "Subprocess timeout in seconds" -> "Timeout (seconds)"                                                                              │
│ - "Model selection patterns" -> "Model routing patterns"                                                                              │
│                                                                                                                                       │
│ ---                                                                                                                                   │
│ Fix 3: Missing tests (ADR Q6 alignment)                                                                                               │
│                                                                                                                                       │
│ File: .claude/hooks/test_hook.sh                                                                                                      │
│                                                                                                                                       │
│ 3a: Add Test #8 — TS sonnet model (type-aware rule)                                                                                   │
│                                                                                                                                       │
│ Insert after: Test #10 (haiku model, line 432), before Test #11                                                                       │
│ (opus model, line 434).                                                                                                               │
│                                                                                                                                       │
│ The ADR specifies useExhaustiveDependencies for sonnet routing.                                                                       │
│ This rule is a Biome lint/nursery rule that matches sonnet_patterns                                                                   │
│ in config.json. Test uses test_ts_model helper:                                                                                       │
│                                                                                                                                       │
│ test_ts_model "TS type-aware -> sonnet" \                                                                                             │
│   "${temp_dir}/ts_sonnet.tsx" \                                                                                                       │
│   'import { useEffect } from "react";                                                                                                 │
│ function App({ dep }: { dep: string }) {                                                                                              │
│   useEffect(() => { console.log(dep); }, []);                                                                                         │
│   return null;                                                                                                                        │
│ }' \                                                                                                                                  │
│   "sonnet"                                                                                                                            │
│                                                                                                                                       │
│ Gate: This test only runs inside the existing if [[ -n "${biome_cmd}" ]] block. If Biome doesn't flag                                 │
│ useExhaustiveDependencies (rule may require React configured in                                                                       │
│ biome.json), fall back to using another sonnet-pattern rule from                                                                      │
│ config.json. Verify during implementation by running biome lint on the                                                                │
│ fixture first.                                                                                                                        │
│                                                                                                                                       │
│ 3b: Add Test #11 — Nursery advisory output                                                                                            │
│                                                                                                                                       │
│ Insert after: Test #8 (violations output, line 377), using the                                                                        │
│ existing test_ts_output helper.                                                                                                       │
│                                                                                                                                       │
│ test_ts_output "TS nursery advisory" \                                                                                                │
│   "${temp_dir}/nursery.ts" \                                                                                                          │
│   '<content triggering a nursery rule>' \                                                                                             │
│   'hook:advisory'                                                                                                                     │
│                                                                                                                                       │
│ Gate: Biome-gated. The fixture needs to trigger a                                                                                     │
│ lint/nursery/* rule. Verify by testing biome lint --reporter=json                                                                     │
│ on the fixture during implementation — if no nursery rule fires with                                                                  │
│ default biome config, this test becomes a conditional skip (nursery                                                                   │
│ rules depend on biome.json configuration).                                                                                            │
│                                                                                                                                       │
│ 3c: Expand deferred tool placeholders (17-21)                                                                                         │
│                                                                                                                                       │
│ Current: 3 placeholder skips (oxlint, tsgo, knip).                                                                                    │
│ ADR spec: 5 deferred tests (17: oxlint type-aware, 18: oxlint                                                                         │
│ disabled, 19: oxlint timeout, 20: tsgo session advisory, 21: tsgo                                                                     │
│ disabled).                                                                                                                            │
│                                                                                                                                       │
│ Replace the 3-line block at lines 497-502 with 5 individual skips:                                                                    │
│                                                                                                                                       │
│ echo "[skip] #17 oxlint: type-aware violation (deferred)"                                                                             │
│ echo "[skip] #18 oxlint: disabled default (deferred)"                                                                                 │
│ echo "[skip] #19 oxlint: timeout gate (deferred)"                                                                                     │
│ echo "[skip] #20 tsgo: session advisory (deferred)"                                                                                   │
│ echo "[skip] #21 tsgo: disabled default (deferred)"                                                                                   │
│                                                                                                                                       │
│ Note: Knip is not in the ADR test table (tests 17-21 cover only                                                                       │
│ oxlint and tsgo). Knip testing would be a future addition.                                                                            │
│                                                                                                                                       │
│ 3d: Drop pre-commit test #13                                                                                                          │
│                                                                                                                                       │
│ The ADR test #13 ("Pre-commit: format skip") tests pre-commit run biome-format directly, which is outside the hook's scope — it tests │
│ pre-commit infrastructure, not multi_linter.sh. The original plan                                                                     │
│ included it but it requires pre-commit installed and configured. Skip                                                                 │
│ this test — the pre-commit hook's command -v biome || exit 0 pattern                                                                  │
│ is trivially correct and doesn't warrant a unit test dependency on                                                                    │
│ pre-commit.                                                                                                                           │
│                                                                                                                                       │
│ ---                                                                                                                                   │
│ Verification                                                                                                                          │
│                                                                                                                                       │
│ 1. shellcheck .claude/hooks/multi_linter.sh — no new warnings                                                                         │
│ 2. markdownlint .claude/hooks/README.md — 0 violations                                                                                │
│ 3. .claude/hooks/test_hook.sh --self-test — all tests pass                                                                            │
│ 4. Manual: process a .css file through the hook, confirm no Semgrep                                                                   │
│ session file entries for CSS                                                                                                          │
│                                                                                                                                       │
│ ---                                                                                                                                   │
│ Files Modified                                                                                                                        │
│                                                                                                                                       │
│ ┌───────────────────────────────┬───────────────────────────────────┐                                                                 │
│ │             File              │              Changes              │                                                                 │
│ ├───────────────────────────────┼───────────────────────────────────┤                                                                 │
│ │ .claude/hooks/multi_linter.sh │ +1 line (CSS guard)               │                                                                 │
│ ├───────────────────────────────┼───────────────────────────────────┤                                                                 │
│ │ .claude/hooks/README.md       │ ~12 lines (table shortening)      │                                                                 │
│ ├───────────────────────────────┼───────────────────────────────────┤                                                                 │
│ │ .claude/hooks/test_hook.sh    │ ~+20 lines (tests + placeholders) │                                                                 │
│ └───────────────────────────────┴───────────────────────────────────┘               
