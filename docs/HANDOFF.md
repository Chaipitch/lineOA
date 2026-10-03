# Handoff — state of the build

Last updated: **2026-09-30**, after sticker pictures (Beta 5). Read `README.md` first, then this file, then `DECISIONS.md`.
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
| M7 Files & images | **Part done:** stickers show as pictures (DEC-32). Images, video, audio and files still show placeholders. |
| M8 Admin UI | **Partly done:** settings and OA registration (DEC-25), nightly jobs card (DEC-29). **Not done:** rotate secret, reassign, deactivate, quota (M8a–c), error log. |
| **M9 Daily Event sync** | **Done, proven live** in the QA org on Beta 4 (DEC-28–30). Two follow-ups proposed for Beta 5 (§4). |
| M10–M12 | Not started. |

Checks on 2026-09-30 (after stickers): **189/189 Apex tests** and **28/28 Jest tests** pass, org-wide coverage **93%**,
Code Analyzer **0 Critical/High**, Prettier and ESLint clean.

**Beta 4 (`0.1.0.4`, `04tgL000000WOs1QAG`)**: M9, the first-message notification fix and the `registerOA` cleanup.
**Installed in the QA org** by the user on 2026-09-29.

**Beta 5 (`0.1.0.5`, `04tgL000000WjGXQA0`) built 2026-09-30**, 94% coverage: Beta 4 plus sticker pictures (DEC-32). The CSP
Trusted Site packaged without problems. **Not yet installed in the QA org.** Install link:
`https://login.salesforce.com/packaging/installPackage.apexp?p0=04tgL000000WjGXQA0`. Before uninstalling Beta 4, remove
`lineChat` from the Contact page and the guest permission set assignment (§5), then put both back.

## 2. Orgs and access

| Alias | What it is | Notes |
|---|---|---|
| `sf-line-dev` | **Dev Hub** (Enterprise Edition trial, expires 2027-09-22). Owns the package and the namespace link | Never deploy source here. Limits: 3 active scratch orgs, 6 package versions a day. |
| `chaipitch-devhub` | **QA org** (Developer Edition, never expires). **Beta 4 (0.1.0.4) installed** | Real LINE OA **TS Chaipitch** (`@803ctlbv`, channel `2011659553`) registered, webhook OK. Site `LineWebhook`: `https://orgfarm-8b3a291438-dev-ed.develop.my.salesforce-sites.com/linewebhook`. Org and admin time zone **Asia/Bangkok** (changed 2026-09-30). Nightly job scheduled, but still at the old time (§4). Contact "Chaipitch" auto-created from a real message. |
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

- **M9 in the installed package (Beta 4, 2026-09-29/30):** *Sync today now* completed with 0 errors and wrote the Event
  (subject, Who, blank What for a Contact without an Account, Show as Free, transcript); the nightly job was
  **scheduled from the LINE Admin page by a subscriber admin**, which only an installed package could prove.

## 4. Open items

1. **Quota: display only, or block sending?** The BA's TA review document proposes blocking; the plan (06 M8a–c) only
   displays. Needs a decision before the TA review on **7 Oct 2026**. See `BA_TA_REVIEW_CORRECTIONS.md` section B.
2. **BA document corrections** (`BA_TA_REVIEW_CORRECTIONS.md`) are with the user to pass on before 7 Oct.
3. **Reschedule the nightly job in the QA org** (LINE Admin → Nightly jobs → Schedule). It was scheduled while the admin
   was on New York time, so it fires at 05:00 UTC (noon Bangkok), not 01:00 Bangkok. A schedule keeps the time zone it
   was created in. The user was told that letting the noon run happen first rebuilds the deleted 29 Sep Event.
4. **Proposed for Beta 5** (the user is choosing):
   - (Not in Beta 5, still proposed.) Show the org time zone on the Nightly jobs card, and warn when the admin's differs. On 2026-09-29 the QA org was
     on Los Angeles time, so Bangkok's evening of the 29th and morning of the 30th fell on the same "day" and one Event
     held both. Correct per DEC-30, invisible to the admin.
   - **Bug:** an Event can end before its last message. Salesforce keeps Event length in whole minutes and recomputes
     `EndDateTime` from the start, dropping seconds. Fix: round the start down and the end up to the minute.
   - Optional *Sync a date*: rebuild a past day's Events. Today a subscriber can't run the sync for any date but today.
5. **Secret cleanup (agreed, not built):** today no secret is ever deleted, and subscriber admins can't reach them.
   Planned in 06 M8: *Remove OA*, a nightly credentials check, and deleting the secret with its OA record.
6. **[VERIFY] same LINE user ID across OAs under one Provider** (D5): auto-link across OAs depends on it. Test in M6
   with a second OA.
7. **Business questions** in `08`: managers replying on a rep's behalf, retention period, invite wording, one active OA
   per rep enforced or not, Opportunity links.
8. **Small bug, not fixed:** the OA table's Active/Inactive badge on the LINE Admin page sets a `variant` attribute that
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
- **Uninstall is refused while** `LINE_Webhook_Guest` is assigned to the guest user, or `lineChat` sits on a Contact
  Lightning page. Remove both first (the page in App Builder: the QA org gets no source deploys), then add them back.
- **"Days" come from the org's default time zone, schedules from the scheduling admin's.** Check both before judging the
  daily Events, and reschedule after changing either.
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

1. **Reschedule the nightly job** in the QA org (§4 item 3).
2. **Before the TA review on 7 Oct:** settle quota (display or block) and pass the BA corrections on. The quota answer
   decides whether M8 needs new packaged fields and a *Blocked* status.
3. **Beta 5 fixes** (§4 item 4): time zone on the Nightly jobs card, Event end-time rounding; *Sync a date* if wanted.
4. **Rest of M6**: QR invite codes, manual link, `lineInbox`. Needs a second OA for the cross-OA [VERIFY].

## 8. Starting a new session

```
Read docs/README.md, docs/HANDOFF.md and docs/DECISIONS.md, then continue with M<n> of docs/06-implementation-plan.md.
```

Useful commands:

```bash
DEVHUB=sf-line-dev DAYS=30 ./scripts/setup-scratch.sh line-dev  # fresh namespaced scratch org, fully set up
sf project deploy start --target-org line-dev --wait 15 --ignore-conflicts
sf apex run test --test-level RunLocalTests --target-org line-dev --code-coverage --result-format human --wait 30
npm run prettier:verify && npm run lint && npm run test:unit
sf package version create --package "LINE Connect" --installation-key-bypass --code-coverage --wait 90 --target-dev-hub sf-line-dev
```
