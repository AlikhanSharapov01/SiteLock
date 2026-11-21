# Agents

SiteLock work is split between one orchestrator and three narrow workers. The orchestrator talks
to the user, keeps the plan, dispatches workers, integrates their results and writes the final
report. Workers return conclusions with `file:line`, not file dumps.

| Role | Definition | Model | Owns / may modify | Hands back |
|---|---|---|---|---|
| Orchestrator | (main session) | strongest available | plan, integration, `README.md`, `AGENTS.md`, `CLAUDE.md`, `HANDOFF.md` | report to the user |
| Researcher | `.claude/agents/researcher.md` | haiku | nothing (read-only) | facts with source URLs; what could not be confirmed |
| Implementer | `.claude/agents/implementer.md` | sonnet | `Sources/`, `Resources/`, `scripts/`, `install.sh`, `uninstall.sh`, `Package.swift` | list of changed files + what changed + build/test output |
| Reviewer | `.claude/agents/reviewer.md` | sonnet | `Tests/` only (may add tests) | findings ranked by severity with `file:line`; test results |

## Boundaries

- The researcher never edits files. Sources: official Mozilla / Apple documentation and the
  Firefox source tree; it flags anything it could not confirm.
- The implementer does not change tests to make them pass; a failing test goes back to the
  orchestrator.
- The reviewer gets the spec (README "How it works" + the user's requirements), not the
  implementer's reasoning. It checks the result against the spec, runs the tests, and reports.
- Nobody commits to `main`, opens or merges PRs, or runs `install.sh` / `uninstall.sh` / anything
  that changes system state on the user's Mac. Commits happen on feature branches, without any
  AI attribution.

## How v1 was run

- Researcher: verified the Firefox macOS policy mechanism (`policy-templates` mac docs and the
  Firefox source: provider precedence, startup-only `WebsiteFilter`, 1000-pattern limit).
- Orchestrator: implemented v1 directly, because the core, daemon and app share one small design
  and splitting them would have cost more context than it saved.
- Reviewer: independent review of the finished branch against the spec, plus the Linux test run.
