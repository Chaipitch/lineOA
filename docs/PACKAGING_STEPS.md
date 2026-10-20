# Packaging steps — how we build and release LINE Connect

A step-by-step guide to cutting a new version of the **LINE Connect** managed 2GP package (namespace `tsthlineoa`).
For the *why* (environments, upgrade-safety rules, security review), read [09-packaging.md](09-packaging.md).
For the current state (last release, open items), read [HANDOFF.md](HANDOFF.md).

## The flow at a glance

```
 scratch org (line-dev)          Dev Hub (sf-line-dev)              test org                     client / production
 ─────────────────────          ─────────────────────              ────────                     ───────────────────
 1. build + test     ──commit──▶ 3. package version create ──04t──▶ 4. install beta,       ──OK──▶ 6. install released
 2. pre-flight checks             (beta, e.g. 0.4.0-1)               run checks                     version (upgrade
                                  5. promote (owner approval) ◀──────┘                               in place)
                                                                                         7. bump version, docs, commit, push
```

- **Beta** = any version that hasn't been promoted. Installs only into **Developer Edition or sandbox** orgs, and can't be upgraded.
- **Released** = promoted. Installs anywhere, upgrades in place, and **everything in it is permanent** (09 §4).

## 0. One-time setup (per developer)

| Need | How |
|---|---|
| Salesforce CLI (`sf`) and Node | `npm install` in the repo root (Prettier, ESLint, Jest, husky) |
| Dev Hub access | A user in the Dev Hub `sf-line-dev` with the permission to create 2GP package versions (ask the package owner). Then `sf org login web --alias sf-line-dev` |
| A namespaced scratch org | `DEVHUB=sf-line-dev DAYS=30 ./scripts/setup-scratch.sh line-dev` (redirect output to a file; never pipe it into `head`) |
| A test org | The QA org `chaipitch-devhub` (Developer Edition) or a sandbox of the production org. `sf org login web --alias <alias>` (sandbox: add `--instance-url https://test.salesforce.com`) |

Limits to know: the Dev Hub allows **6 package versions a day** and 3 active scratch orgs.

## 1. Decide the version number

`sfdx-project.json` → `packageDirectories[0].versionNumber`, format `MAJOR.MINOR.PATCH.NEXT`.

- After each release we bump the **minor** number (0.3.0 → 0.4.0). `NEXT` makes the build number count up: `0.4.0-1`, `0.4.0-2`, …
- `"ancestorVersion": "HIGHEST"` stays as it is. It makes Salesforce validate every new build as an upgrade of the last release,
  and the build **fails** if a packaged component was removed or changed in a way that isn't allowed.
- Don't edit `packageAliases` by hand; the CLI adds the new alias in step 3.

## 2. Pre-flight checks (all must pass)

Start from a clean, committed `main`. Write down the commit hash: the version is built from it.

```bash
npm run prettier:verify
npm run lint
npm run test:unit                                  # LWC Jest
./scripts/code-analyzer.sh                         # fails on any Critical/High finding; report in reports/
sf project deploy start --target-org line-dev --wait 10
sf apex run test --test-level RunLocalTests --target-org line-dev --code-coverage --result-format human --wait 30
```

Pass bar: every class ≥ 75 %, overall ≥ 85 %, no Critical/High Code Analyzer findings.

**Upgrade-safety review.** List what changed in `force-app/` since the last release and check that nothing packaged was deleted or renamed:

```bash
LAST=$(git log --grep='^Release' -1 --format=%h)            # the last release commit
git diff --name-status --diff-filter=DR "$LAST" -- force-app   # must print nothing (D = deleted, R = renamed)
git diff --stat "$LAST" -- force-app                           # review the rest
```

Any new object, field, picklist value, `global` member, custom setting, custom permission or platform event must match
[03-data-model.md](03-data-model.md) exactly: once released it can't be renamed or removed. `global` is allowed only on
`LineWebhookResource`. If something must be removed, stop and talk to the package owner first.

## 3. Build the beta

```bash
sf package version create --package "LINE Connect" --installation-key-bypass \
  --code-coverage --wait 90 --target-dev-hub sf-line-dev
```

- It takes roughly 10–30 minutes. Salesforce spins up a temporary build org, deploys `force-app/`, and runs **all** Apex tests there.
- On success it prints the **subscriber package version Id** (`04t…`) and adds an alias such as `"LINE Connect@0.4.0-1"`
  to `packageAliases` in `sfdx-project.json`. Commit that change.
- Check the result:

  ```bash
  sf package version report --package "LINE Connect@0.4.0-1" --target-dev-hub sf-line-dev
  ```
  Look for *Code Coverage Met: true* and *Validation Skipped: false*. Without both, the version can't be promoted.
- `--installation-key-bypass` means anyone with the link can install. Use `--installation-key <key>` instead for
  anything shared outside the team, and keep the key in a password manager, never in the repo.

**When the build fails but the scratch org was green**, it's usually one of these (see HANDOFF §5):

| Symptom | Cause / fix |
|---|---|
| A test fails with "No such column" or insufficient access on a package object | The build org's test user has **none** of our permission sets. Every test calls `LineTestFactory.ensurePackageAccess()`, and every query/DML on package objects in tests uses `WITH SYSTEM_MODE` / `insert as system` (even `SELECT COUNT()`) |
| Translation or Thai label errors | `"definitionFile": "config/project-scratch-def.json"` is missing from the package directory |
| "Ancestor" / "component removed" error | A packaged component was deleted or changed in a way the release doesn't allow. Restore it (see step 2) |

## 4. Install and test the beta

Pick the test org:

- **Upgrade test (preferred, required from the first release on):** the company sandbox **`dev5-ts`**, which has the
  current released version installed. Install the beta over it; this is how production will get it.
- **QA org `chaipitch-devhub`:** if an older **beta** is installed there, uninstall it first (betas can't be upgraded; its data is lost).
  Before uninstalling, remove `LINE_Webhook_Guest` from the Site guest user and remove `lineChat` from any Contact
  Lightning page in App Builder, or Salesforce refuses the uninstall.

```bash
sf package install --package "LINE Connect@0.4.0-1" --target-org <test-org-alias> --wait 30 --publish-wait 15
```

Or open the install link in the browser (`p0` = the `04t` Id; use `test.salesforce.com` for a sandbox):
`https://login.salesforce.com/packaging/installPackage.apexp?p0=04t...`

After install, check:

1. Permission sets are still assigned: `LINE_Webhook_Guest` on the Site guest user; `LINE_Admin` / `LINE_Chat_User` on people.
2. **LINE Admin** page loads, and existing OA configurations show as Valid.
3. Send a LINE message from a phone to a rep's OA → it appears in the Contact's chat panel.
4. Reply from Salesforce → it arrives on the phone.
5. Whatever the release changed (the fix or feature), checked by hand.
6. `LINE_Error_Log__c` has no new errors.

Never `sf project deploy` to the QA org or to production: they get **installed versions only**.

## 5. Promote (release)

> **Only with the package owner's explicit go-ahead.** A promoted version can't be deleted, and every component in it becomes permanent.

```bash
sf package version promote --package "LINE Connect@0.4.0-1" --target-dev-hub sf-line-dev
```

## 6. Install in production / client orgs

- Upgrades are **in place**; data is kept. Install from the link above (production: `login.salesforce.com`, sandbox: `test.salesforce.com`), or with
  `sf package install` as in step 4.
- Recommended: try the same version in a sandbox of that org first.
- Run the step 4 checks again afterwards.
- Subscriber setup (Site, webhook URL, permission sets, LINE console settings) is in [05-setup-runbook.md](05-setup-runbook.md) Part B.

## 7. Housekeeping after a release

In one commit named `Release <version> (DEC-nn); next version <next>`:

1. `sfdx-project.json`: bump `versionNumber` to the next minor, e.g. `0.5.0.NEXT`. Keep the new alias in `packageAliases`.
2. `docs/DECISIONS.md`: a DEC entry saying what was released, why, and how it was tested (or that an upgrade test was skipped and who decided).
3. `docs/HANDOFF.md`: the release line (version, `04t` Id, install link, the next build number).
4. `docs/README.md`: the "Released" list.

Then push `main` to both remotes:

```bash
git push origin main && git push scratchorg main
```

## Quick reference

| Task | Command |
|---|---|
| List all versions | `sf package version list --packages "LINE Connect" --target-dev-hub sf-line-dev` |
| Details of one version | `sf package version report --package "LINE Connect@0.4.0-1" --target-dev-hub sf-line-dev` |
| What's installed in an org | `sf package installed list --target-org <alias>` |
| Build status if `--wait` timed out | `sf package version create report --package-create-request-id 08c... --target-dev-hub sf-line-dev` |

Released so far: `0.1.0.10`, `0.2.0.1`, `0.3.0.1` (see `packageAliases` and HANDOFF §1 for the `04t` Ids).
