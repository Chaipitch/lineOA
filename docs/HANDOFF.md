# Handoff — state of the build

Last updated: **2026-09-30**, after M9 and the daily-sync time-zone fix (DEC-32). Read `README.md` first, then this file, then `DECISIONS.md`.
This file says where the work stands, what's open, and which traps already cost time. Keep it current at the end of each
milestone. For how the system works, read `HOW_IT_WORKS.md`.

## 1. Where we are

| Milestone | State |
|---|---|
| M0 Packaging foundation | **Done.** Namespace `tsthlineoa`, package `LINE Connect` (`0HogL0000004bNZSAY`) owned by Dev Hub `sf-line-dev`. |
| M1 Data model & security metadata | **Done.** |
| M2 Core services | **Done.** |
| M3 Registration + inbound | **Done, proven live** in a scratch org and in the installed package. |
| M4 Outbound text | **Done, proven live**: a reply sent from Salesforce reached a real phone. |
| M5 Chat panel (`lineChat`) | **Done, proven live** on a Contact page in the QA org. |
| M6 Linking + inbox | **Partly done:** auto-link and auto-create Contact on first message (DEC-27). **Not done:** QR invite codes, manual link, `lineInbox`, `lineInvite`. |
| M7 Files & images | Not started. |
| M8 Admin UI | **Partly done:** settings and OA registration (DEC-25), nightly jobs card (DEC-29). **Not done:** rotate secret, reassign, deactivate, quota (M8a–c), error log. |
| **M9 Daily Event sync** | **Done in the scratch org** (DEC-28–30): 187/187 Apex tests. Not yet in a package version. |
| M10–M12 | Not started. |

Checks at the end of M9: **187/187 Apex tests** and **25/25 Jest tests** pass, org-wide coverage **93%** (lowest class
`LineAdminController` 87%), Code Analyzer **0 Critical/High**, Prettier and ESLint clean.

**Beta 4 (`0.1.0.4`, `04tgL000000WOs1QAG`) built 2026-09-29**, 94% coverage: M9, the first-message notification fix
and the `registerOA` cleanup. Not yet installed in the QA org (the user installs it; Beta 3 must be uninstalled first).

## 2. Orgs and access

| Alias | What it is | Notes |
|---|---|---|
| `sf-line-dev` | **Dev Hub** (Enterprise Edition trial, expires 2027-09-22). Owns the package and the namespace link | Never deploy source here. Limits: 3 active scratch orgs, 6 package versions a day. |
| `chaipitch-devhub` | **QA org** (Developer Edition, never expires). **Beta 3 (0.1.0.3) installed** | The real LINE OA **TerraskyTH-Dev-Acc** (`@833ybxes`, channel `2011724597`) is registered here, and its webhook points here. Site `LineWebhook`: `https://orgfarm-8b3a291438-dev-ed.develop.my.salesforce-sites.com/linewebhook`. Contact "Chaipitch" was auto-created from a real message. |
| `line-dev` | **The one scratch org** (namespaced `tsthlineoa`, user `test-egv3lqxcpg7t@example.com`); the project default | Expires **2026-10-22**. Rebuild: `DEVHUB=sf-line-dev DAYS=30 ./scripts/setup-scratch.sh line-dev`. Holds seed data from `scripts/apex/seed-daily-sync.apex`. Until 2026-09-29 this org was aliased `line-ns`; the old non-namespaced `line-dev` was deleted that day. |

**Another active scratch org** is listed in the Dev Hub, `test-bdmfveozrgxg@example.com`, which this machine has no login
for. It takes one of the 3 slots. The user was asked whether they recognise it; don't delete it without asking.

The OA is on the **free LINE plan (300 push messages a month)**. Don't run bulk-send tests against it.

**Git:** two remotes, both kept in step: `origin` = `git@github.com:Chaipitch/lineOA.git` (SSH, account `Chaipitch`)
and `scratchorg` = `https://github.com/wchaipitch-ts/sf-line-dev-scratchorg.git`. Push `main` to both.

## 3. What is proven to work live

- A real phone → LINE → Site guest user → signature check → platform event → Automated Process → conversation and
  message stored → rep notified. Verified in a scratch org and in the installed package in the QA org.
- Profile callout names the conversation; auto-create makes the Contact (QA org, 2026-09-24).
- Reply from the chat panel delivered to the phone.
- Fake signature → 401, unknown OA → 403, junk → 400, and nothing is stored.
- In the installed package, the protected setting `LINE_OA_Credential__c` is invisible to a subscriber System
  Administrator (SOQL returns "not supported").
- Registering an OA from the LINE Admin page sets the webhook URL at LINE.

**Daily sync in the QA org (2026-09-30):** it ran and created Events, but one Event held yesterday's and today's
conversation. Cause: the org's Default Time Zone is not Bangkok, and a day is midnight to midnight in the org's time zone
(DEC-30). Fix (DEC-32, config only): set Setup → Company Information → Default Time Zone to Asia/Bangkok, then press
**Sync today now** and check that each day has its own Event (07 §3 step 9). The next beta adds a warning on the Nightly
jobs card when the org and admin time zones differ.

## 4. Open items

1. **Quota: display only, or block sending?** The BA's TA review document proposes blocking; the plan (06 M8a–c) only
   displays. Needs a decision before the TA review on **7 Oct 2026**. See `BA_TA_REVIEW_CORRECTIONS.md` section B.
2. **BA document corrections** (`BA_TA_REVIEW_CORRECTIONS.md`) are with the user to pass on before 7 Oct.
3. **Beta 4** with M9 and the notification fix. Installing it means uninstalling Beta 3 first, which deletes the package's
   data in the QA org. **Ask before uninstalling anything from the QA org.**
4. **[VERIFY] same LINE user ID across OAs under one Provider** (D5): auto-link across OAs depends on it. Test in M6
   with a second OA.
5. **Business questions** in `08`: managers replying on a rep's behalf, retention period, invite wording, one active OA
   per rep enforced or not, Opportunity links.
6. **QA org time zone:** set the Default Time Zone to Asia/Bangkok and re-check the daily Events (DEC-32). The
   time-zone warning on the LINE Admin page is in source only, not yet in a package version.
7. **Small bug, not fixed:** the OA table's Active/Inactive badge on the LINE Admin page sets a `variant` attribute that
   `lightning-badge` doesn't have, so it never shows a colour.

## 5. Traps already hit (don't rediscover these)

**Package build org**
- **Tests in the package build org run as a user with none of the package permission sets.** Every test method calls
  `LineTestFactory.ensurePackageAccess()` first, **and every query or DML on a package object or field uses
  `WITH SYSTEM_MODE` / `insert as system`**, including `SELECT COUNT()`. A query that passes in every scratch org fails
  only in the build (DEC-24; bit us again in Beta 3). `WITH SYSTEM_MODE` goes before `ORDER BY` / `LIMIT`.
- **The build org is created from a default scratch definition** unless the package directory has
  `"definitionFile": "config/project-scratch-def.json"`, which Thai translations need (Translation Workbench).
- **`sf package create` rewrites `sfdx-project.json`** (sets `"default": false`, renames `versionName`). Check it after.

**Installed package**
- **Betas can't be upgraded.** Uninstall the old beta first, which deletes its data. Afterwards, check the permission
  set assignments (`LINE_Webhook_Guest` on the Site guest user; `LINE_Admin`, `LINE_Chat_User` on people). The Site
  itself survives.
- **Only `global` members are callable in a subscriber org**, and the only global class is the webhook. Anything an admin
  must run (register an OA, schedule a job) needs a button on the LINE Admin page (DEC-25, DEC-29).
- **Betas install only into Developer Edition or sandbox orgs**, which is why the QA org is `chaipitch-devhub`.
- **"Use webhook" must be ON** (Developers Console → Messaging API tab), or messages silently never arrive. The Verify
  button returns 200 even while it is off. On 2026-09-24 the QA org received nothing until the webhook settings were
  checked; OA Manager's Response settings (Webhooks on) were reviewed at the same time, so which one was off wasn't
  isolated. Chat mode on or off is the client's choice (05 Part B).

**Apex**
- **Apex strings take single quotes only.** A double-quoted assertion message fails to parse, in Prettier too.
- **Don't name a variable `json`** (hides the `JSON` class). **Apex `==` on Strings ignores case.**
- **Callout after DML** fails with "uncommitted work pending" (DEC-26).
- **Test helpers that query per call** (e.g. the org time zone) hit 100 SOQL in bulk tests. `orgTimeZone()` is now cached.
- **`getNumDml()` on a `DmlException` you constructed throws an uncatchable error.** Match on the message.
- **Event/Task custom fields live on `Activity`**, and permission-set entries must read `Activity.<field>` (DEC-10).
- **Scratch orgs have very few licences.** Keep tests to at most 2 new users; `LineTestFactory.createUser` handles it.

**Tooling**
- **`--json` output from `sf` can start with a CLI-update warning line**, which breaks JSON parsing. Check the text, not
  just the parser.
- **Running Apex tests makes source tracking report conflicts**; `--ignore-conflicts` is safe in our scratch orgs.
- **Salesforce's docs site refuses automated fetches.** Use LINE's OpenAPI specs at `github.com/line/line-openapi`, and
  check Salesforce behaviour with a `--dry-run` deploy to a scratch org.

## 6. Conventions worth knowing before editing

- Secrets live only in `LINE_OA_Credential__c`, and only `LineCredentialStore` touches it. Nothing else may carry a
  secret. `LineLogger` also masks anything that looks like a token.
- Callouts before DML in every transaction. The webhook does no DML at all, not even logging.
- All user-facing text comes from Custom Labels, with a Thai translation added at the same time.
- Every packaged API name is permanent once released. Check `03` before creating any field, picklist value or object.
- `global` only on `LineWebhookResource`. `without sharing` only where `02` §2 lists it, with the reason in the class.

## 7. Suggested next steps

1. **Beta 4** (M9 + notification fix) → QA org → press *Sync today now* → check the Event on the Contact.
2. **Settle quota** (display or block) before 7 Oct.
3. **Rest of M6**: QR invite codes, manual link, `lineInbox`.

## 8. Starting a new session

```
Read docs/README.md, docs/HANDOFF.md and docs/DECISIONS.md, then continue with M<n> of docs/06-implementation-plan.md.
```

Useful commands:

```bash
DEVHUB=sf-line-dev DAYS=30 ./scripts/setup-scratch.sh line-dev  # fresh namespaced scratch org, fully set up
./scripts/create-reps.sh chaipitch-devhub <your email> 3        # test reps with LINE_Chat_User (multi-rep testing)
sf project deploy start --target-org line-dev --wait 15 --ignore-conflicts
sf apex run test --test-level RunLocalTests --target-org line-dev --code-coverage --result-format human --wait 30
npm run prettier:verify && npm run lint && npm run test:unit
sf package version create --package "LINE Connect" --installation-key-bypass --code-coverage --wait 90 --target-dev-hub sf-line-dev
```
