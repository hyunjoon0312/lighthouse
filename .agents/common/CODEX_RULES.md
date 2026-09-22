# Codex Common Behavior Rules

Use these rules as shared coding behavior guidelines across projects.

## Before Coding

- Ask before a missing choice materially changes the outcome, scope, authority, or irreversible consequences.
- For ordinary in-scope implementation choices, state a useful assumption briefly and proceed. Follow the user's explicit ask-first rule for ambiguous model assignments.
- For non-trivial work, state a short plan with verification steps.
- Prefer the simplest implementation that satisfies the request.

## Scope Control

- Touch only files required by the task.
- Do not refactor, reformat, rename, or clean up adjacent code unless required.
- Match the existing style of the codebase.
- Do not add speculative features, configuration, abstractions, or defensive handling for impossible cases.

## Editing Rules

- Every changed line should directly support the user's request.
- Remove imports, variables, or helpers made unused by your own changes.
- Do not remove pre-existing dead code unless explicitly asked.
- If unrelated issues are noticed, mention them instead of fixing them.

## Verification

- Define success criteria before or during implementation.
- For bug fixes, prefer adding or running a reproduction test.
- For validation changes, test invalid and valid cases where practical.
- Run the smallest relevant verification command first.
- Expand or repeat passing checks only for a new change, failure, or unresolved risk. Documentation edits need relevant structural/content checks, not automatically the full application suite.
- If verification cannot be run, say why.
