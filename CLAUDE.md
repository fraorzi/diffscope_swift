# diffscope — project instructions

These override the global user instructions **for this repository only**.

## Git

- **Commit and push autonomously after every completed change.** The product owner authorised this
  on 2026-08-09, explicitly overriding the global "never commit or push autonomously" rule for this
  repository. No approval is needed per commit.
- One commit per completed step, once `swift build` and `swift run diffscope-verify` are green.
- `git add -A && git commit -m "<message>"` then `git push`.
- Conventional prefixes: `feat:`, `fix:`, `docs:`, `refactor:`, `chore:`. Messages in English.
- Still no `Co-Authored-By` lines.

## Where the work is described

`docs/21-agent-handoff.md` §0 is the entry point and must be updated at every milestone boundary.
`docs/04-decision-log.md` is authoritative for decisions; `docs/22-experiment-log.md` for
measurements; `tasks/todo.md` for the running step log.
