# Multi-agent workflow

Drop this file into a project root as `AGENTS.md`. Every agent working on
the project reads it first and follows it. One project, one home, one
writer at a time.

## Roles

- **Rio (planner / memory / shipper).** Owns the spec, the project
  memory (infrastructure, deploy steps, exact user-facing wording, past
  decisions), reviews diffs, and writes deploy commands. Every feature
  starts and ends with Rio.
- **Claude Code (builder).** Implements in the repo, runs tests,
  iterates until green. The only agent that edits code during a build
  step.
- **Gemini / Antigravity (reviewer / architect).** Reads the whole
  project in one pass and reviews diffs for bugs and security issues —
  not style nits. Never the builder on an existing codebase: it tends
  to redesign instead of following existing code.
- **DeepSeek / GLM (spares).** Second opinions when builder and
  reviewer disagree. Not part of the core loop.

## The loop (one feature)

1. The owner describes the feature in their own words.
2. Rio writes a short spec: what changes, which tests must pass, and
   the exact user-facing wording (verbatim).
3. Claude Code implements it and runs the full test suite until green.
4. Gemini reviews the diff against the whole project for bugs and
   security issues.
5. Fixes go back to Claude Code (small ones to Rio).
6. Push to the project's home (gist or repo). Rio writes copy-paste
   deploy commands.
7. The owner deploys and live-tests, and reports back with
   screenshots or logs.
8. Only then is it done.

## Rules

- **One writer at a time.** Never two agents editing the same file.
- **Green tests before ship.** An edit-success report is not proof.
  Run the suite.
- **Handoffs go through the repo/gist plus the spec.** Agents do not
  message each other.
- **Read existing source before changing it.** Never redesign from
  scratch when code already exists.
- **Verify against live state,** not cached output or tests that
  bypass the real path.
- **User-facing wording is the owner's, verbatim.** Do not paraphrase
  it.
- **Secrets live only in `.env` on the server, untracked.** Never in a
  gist, a repo, or a chat log. If one leaks, rotate it once and move on.
- **Policy calls are the owner's:** auth rules, broadcasts to users,
  grading, anything that affects users. Agents propose, the owner
  decides.
- **Deploy is the owner's hands.** Agents prepare commands, the owner
  runs them.

## Project homes

- Existing projects keep their home (for example, the Telegram bot and
  the shifts page live in secret gists).
- New projects start in a private GitHub repo — branches and history
  beat a gist for new work.

## Machines

- Windows is the main build machine: Antigravity IDE and Claude Code
  terminal may share one folder, but never edit with both at once.
- Phone (Termux / proot Debian) is for small fixes on the go, not main
  builds.
