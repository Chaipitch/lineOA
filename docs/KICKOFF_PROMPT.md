# Kickoff prompt

Paste this into a new Claude Code session opened in `/Users/chaipitchwongwangpaisarn/Documents/sf-line-dev`.
`CLAUDE.md` loads automatically and holds the rules; this prompt only starts the work.

---

We're building the LINE Connect managed 2GP package described in `docs/`.
Read `docs/README.md`, `docs/HANDOFF.md` and `docs/DECISIONS.md`, then continue with the next milestone in
`docs/06-implementation-plan.md`. Stop and report back at the end of it.

(The original M0 kickoff, before any code existed, was: "Read `docs/README.md` and then files 01–09 in order, then start
M0: list the [HUMAN] steps for the Dev Hub and namespace, prepare everything else, and stop before M1.")

---

## Prompts for later milestones

- `Continue with M<n> of docs/06-implementation-plan.md.`
- `M<n> [HUMAN] steps are done: <details>. Run the done-criteria check.`
- `Create the next beta and install it into chaipitch-devhub.` (Uninstalling the old beta first deletes its data there: Claude asks first.)
- `Write docs/QA_RESULTS_<version>.md from the E2E run.`
