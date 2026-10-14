# Handoff — state of the build

Last updated: **2026-10-14**, after removing the inbox (DEC-44): linking, files, photos and stickers now all live in the Contact chat panel. Not yet in a beta (Beta 8 still has the old inbox). Read `README.md` first, then this file, then `DECISIONS.md`.
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
| M6 Linking | **Built:** auto-link and auto-create (DEC-27), default Account (DEC-36), D5 proven live, QR invite (DEC-42), manual link with placeholder clean-up and admin unlink **in the chat panel** (DEC-34, DEC-44; the Beta 8 inbox tab is removed). The link icon is **hidden** for now (commented out in `lineChat.html`, tests skipped) until the business wants it. Still to do: the phone test of the invite link. |
| M7 Files & images | **Built in the scratch org (DEC-43), not yet in a beta:** customer images/video/audio/files saved as Salesforce Files on the conversation and Contact (Too Large / Download Failed handled, video waits for LINE's transcoding), thumbnails and file chips in the chat, reps send files (small JPEG/PNG as pictures, the rest as expiring links). **Still to do:** the live [VERIFY] that LINE accepts Salesforce's public URLs, on real phones. |
| M8 Admin UI | **Partly done:** settings and OA registration (DEC-25), nightly jobs card (DEC-29), *Remove OA* and the nightly credentials check (DEC-33), **Rotate secret (DEC-45, scratch only)**. **Not done:** reassign, deactivate, quota display (M8a, display-only per DEC-35), error log viewer. |
| **M9 Daily Event sync** | **Done, proven live** in the QA org on Beta 4 (DEC-28–30). Follow-ups (minute rounding, time zones on the jobs card) shipped in Beta 6. |
| M10–M12 | Not started. M11 now also includes evaluating a no-authentication Named Credential as the callout endpoint (06 M11, 08 "Callout allowlist"). |

Checks on 2026-10-13 (Beta 8 work): **257/257 Apex tests** and **59/59 Jest tests** pass, org-wide coverage **92%**
(every class ≥ 85%), Code Analyzer **0 Critical/High**, Prettier and ESLint clean.

**Beta 4 (`0.1.0.4`, `04tgL000000WOs1QAG`)**: M9, the first-message notification fix and the `registerOA` cleanup.
**Installed in the QA org** by the user on 2026-09-29.

**Beta 5 (`0.1.0.5`, `04tgL000000WjGXQA0`)**: Beta 4 plus sticker pictures (DEC-32). Installed in the QA org.

**Beta 6 (`0.1.0.6`, `04tgL000000X7AnQAK`) built 2026-10-03**, 94% coverage: Beta 5 plus secret cleanup and the
credentials check (DEC-33), Event minute rounding, and time zones on the Nightly jobs card. **Not yet installed in the QA
org.** Install link: `https://login.salesforce.com/packaging/installPackage.apexp?p0=04tgL000000X7AnQAK`. Before
uninstalling Beta 5, remove `lineChat` from the Contact page and the guest permission set assignment (§5), then put both
back.

**Beta 7 (`0.1.0.7`, `04tgL000000YbWbQAK`) built 2026-10-11**, 94% coverage: Beta 6 plus the TA review fixes: default
Account for created Contacts (DEC-36), only the assigned rep (or, for an inactive OA, the fallback owner/queue) can send
(DEC-37), 401 for an unknown OA (DEC-38), same-Provider confirmation at registration (DEC-39). **Not yet installed in the
QA org.** Install link: `https://login.salesforce.com/packaging/installPackage.apexp?p0=04tgL000000YbWbQAK`. Skip Beta 6.
Uninstalling Beta 5 deletes all LINE data, including `Contact.LINE_User_Id__c`, so delete or note the test Contacts
(Chaipitch ×2, Meng) first, or the next message duplicates them.

**Beta 8 (`0.1.0.8`, `04tgL000000Z5BJQA0`) built 2026-10-13**, 92% coverage: Beta 7 plus the 2-second refresh (DEC-40),
the LINE Inbox with manual linking and placeholder clean-up (DEC-34, DEC-41), QR invites (DEC-42) and files and images
(DEC-43). Superseded before install: it still has the LINE Inbox tab, removed in DEC-44; build Beta 9 and install that instead. Install link:
`https://login.salesforce.com/packaging/installPackage.apexp?p0=04tgL000000Z5BJQA0`.

**Beta 9 (`0.1.0.9`, `04tgL000000ZN8DQAW`) built 2026-10-14** from commit `8610719`: Beta 8 without the inbox tab, plus the
LINE-style composer (files, photos, stickers), linking in the chat panel with its button hidden (DEC-44) and the header
divider. Superseded by Beta 10. Install link:
`https://login.salesforce.com/packaging/installPackage.apexp?p0=04tgL000000ZN8DQAW`. Release to the team's own production
org is planned after it checks out (needs `sf package version promote`, the user's explicit go-ahead).

**Beta 10 (`0.1.0.10`, `04tgL000000ZN9pQAG`) built 2026-10-14** from commit `a305bd5`: Beta 9 plus Rotate secret (DEC-45);
R15 decided (error log kept). **This is the one to install** (QA org, or a sandbox of the production org) and, once its
checks pass, the candidate to promote for the team's own production org (`sf package version promote`, the user's
explicit go-ahead). Install link: `https://login.salesforce.com/packaging/installPackage.apexp?p0=04tgL000000ZN9pQAG`.

## 2. Orgs and access

| Alias | What it is | Notes |
|---|---|---|
| `sf-line-dev` | **Dev Hub** (Enterprise Edition trial, expires 2027-09-22). Owns the package and the namespace link | Never deploy source here. Limits: 3 active scratch orgs, 6 package versions a day. |
| `chaipitch-devhub` | **QA org** (Developer Edition, never expires). **Beta 5 (0.1.0.5) installed**; Beta 6 not yet | Real LINE OA **TS Chaipitch** (`@803ctlbv`, channel `2011659553`) registered, webhook OK. Site `LineWebhook`: `https://orgfarm-8b3a291438-dev-ed.develop.my.salesforce-sites.com/linewebhook`. Org and admin time zone **Asia/Bangkok** (changed 2026-09-30). Nightly job **not scheduled** since the Beta 5 install (§4). Contact "Chaipitch" auto-created from a real message. |
| `line-dev` | **The one scratch org** (namespaced `tsthlineoa`, user `test-e8dratclzthk@example.com`); the project default | Created **2026-10-11**, expires **2026-11-10**. Rebuild: `DEVHUB=sf-line-dev DAYS=30 ./scripts/setup-scratch.sh line-dev`, then `sf apex run --file scripts/apex/seed-daily-sync.apex`. Holds that seed data (OA "May Sales OA", Rep A, Somchai, Niran). Org time zone America/Los_Angeles (scratch default). The previous org (`test-egv3lqxcpg7t`) was deleted the same day. |

The unknown scratch org `test-bdmfveozrgxg@example.com` had expired by 2026-10-11. Only `line-dev` is active now.

The OA is on the **free LINE plan (300 push messages a month)**. Don't run bulk-send tests against it.

**Git:** two remotes, both kept in step: `origin` = `git@github.com:Chaipitch/lineOA.git` (SSH, account `Chaipitch`)
and `scratchorg` = `https://github.com/wchaipitch-ts/sf-line-dev-scratchorg.git`. Push `main` to both.

## 3. What is proven to work live

- A real phone → LINE → Site guest user → signature check → platform event → Automated Process → conversation and
  message stored → rep notified. Verified in a scratch org and in the installed package in the QA org.
- Profile callout names the conversation; auto-create makes the Contact (QA org, 2026-09-24).
- Reply from the chat panel delivered to the phone.
- Fake signature → 401, unknown OA → 403 (401 since DEC-38, scratch only), junk → 400, and nothing is stored.
- In the installed package, the protected setting `LINE_OA_Credential__c` is invisible to a subscriber System
  Administrator (SOQL returns "not supported").
- Registering an OA from the LINE Admin page sets the webhook URL at LINE.

- **M9 in the installed package (Beta 4, 2026-09-29/30):** *Sync today now* completed with 0 errors and wrote the Event
  (subject, Who, blank What for a Contact without an Account, Show as Free, transcript); the nightly job was
  **scheduled from the LINE Admin page by a subscriber admin**, which only an installed package could prove.

## 4. Open items

0. **TA review feedback (received 2026-10-07):** no Required findings; 10 Recommended, 3 Optional, 6 At your discretion.
   Source files `~/Downloads/LINE_OA_Architecture_Review.pptx` and `LINE_OA_Review_Findings.xlsx`; our draft answers in
   `~/Downloads/LINE_OA_Review_Findings_draft_responses.xlsx`; BA summary doc
   https://claude.ai/artifact/Du5nL5FvDpa55q3FffPzLr. The TA asked that the feedback be addressed before development continues.
   - **Built in the scratch org, not yet in a beta (user said not to build a package yet, 2026-10-11):** DEC-36
     default Account (TA R4 direction), DEC-37 only the assigned rep (or, for an inactive OA, the fallback owner/queue)
     can send (R1), DEC-38 unknown OA → 401 (R8), DEC-39 same-Provider checkbox at registration (R3).
   - **Beta 7 built 2026-10-11** with all four (§1). Next: the QA reinstall (uninstall deletes LINE data,
     including `Contact.LINE_User_Id__c`, so existing Contacts would be duplicated on the next message).
   - **Decided 2026-10-14 (DEC-45):** R4 auto-create stays on; R6 reps reply only from Salesforce; S1 the chat panel stays.
     **R15 decided: keep `LINE_Error_Log__c`.** **Still open:** licence; the sizing sheet (M11 numbers).
   - **QA org data (2026-10-11):** Account "Chaipitch (test)" created and Contact "Chaipitch" put under it by hand, so
     Rep Sales2 can open it. OAs: TS Chaipitch, TS SalesRep1 (other Provider), SalesRep2 (same Provider as TS Chaipitch).

1. **TA review on 7 Oct 2026.** Materials prepared 2026-10-04/06 (outside the repo):
   - **BA document corrected** with tracked changes and comments: `~/Downloads/LINE_OA_Salesforce_Architecture_Design_TA_Review_corrected.docx`
     (see the "Applied" note in `BA_TA_REVIEW_CORRECTIONS.md`). The user sends it to the BA.
   - **Slide deck** (14 slides: constraints, message flow, 7 decisions each with the likely challenge and our answer,
     Remote Site Settings, capacity in transactions, our own limits, live proof): https://claude.ai/artifact/3WPayEDLjNJ32dMYy8dCE9
   - **One-page cheat sheet**: https://claude.ai/artifact/VxPVQZu3mppMePWrrZu5eT, printable copy
     `~/Downloads/LINE_Connect_TA_cheat_sheet.html`.
   - Both artifacts are shared "anyone with the link". Speaker notes hold the long answers.
   - Positions taken: **we stay on Remote Site Settings** (Named Credential as endpoint only *evaluated* in M11);
     **capacity is answered in transactions** (HOW_IT_WORKS §3.6): fixed cost per transaction, no per-rep limit.
   - Weak spot: CPU/heap for a full 2,000-event transaction is **unmeasured**. Offered to the user: run the M11 load test
     early in `line-dev` (push 2,000 messages in one transaction, record CPU, heap, time; ~half a day). Not answered yet.
   - Before the demo (deck "Proof" notes): Beta 6 installed, OA credentials show Valid, nightly job scheduled, `lineChat`
     on the Contact page, phone with the OA added.
2. **QA org: install Beta 8 (the latest), then schedule the nightly job** (LINE Admin → Nightly jobs → Schedule). It wasn't scheduled
   after Beta 5 was installed. The card shows the org time zone and warns if the admin's differs.
3. **M6 needs, before starting:**
   - the design for recognising auto-created Contacts (DEC-34: linking to the real Contact deletes an empty stub);
   - ✅ The D5 [VERIFY] is done (2026-10-11, QA org): OA *SalesRep2* under the same Provider as *TS Chaipitch* gave the same user ID and
     auto-linked to the existing Contact; *TS SalesRep1*, under a different Provider, gave a new ID and a duplicate Contact (DECISIONS §2).
4. **Optional, not built:** *Sync a date* (rebuild a past day's Events). Today only "today" can be run by hand.
5. **Business questions** in `08`: managers replying on a rep's behalf, retention period, invite wording, one active OA
   per rep enforced or not, Opportunity links.
6. **Small bug, not fixed:** the OA table's Active/Inactive badge sets a `variant` attribute that `lightning-badge`
   doesn't have, so it never shows a colour.

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
- **Never pipe `setup-scratch.sh` (or a deploy) into `head`.** When `head` exits, the script dies of SIGPIPE half-way. On
  2026-10-11 that left an org whose permission sets were deployed before the Activity fields existed, so the admin had no
  access to `Event.LINE_Conversation__c` ("No such column"). Fix: redeploy `permissionsets`. Redirect to a file instead.
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

1. **Install Beta 8 in the QA org** (reinstall checklist: §1 and §5; uninstalling clears `Contact.LINE_User_Id__c`, so
   delete or note the test Contacts first). Set the default Account, register the OAs (tick the Provider box), schedule
   the nightly job.
2. **Phone tests** (the open [VERIFY]s in 08): QR invite on iOS and Android, friend and non-friend; a photo and a PDF
   from the phone appear as Files; a picture and a PDF sent from Salesforce arrive; the read-only panel for a
   non-assigned rep; 401 for an unknown OA. Record the results in DECISIONS §2.
3. **M8 remainder**: reassign/deactivate with `LineReassignBatch` (TA R13, acceptance criterion 5), quota display (M8a), error log viewer.
4. **M10** retention before any high-volume client; **M11** load tests (2,000-event batch, Site limits) and hardening;
   **M12** acceptance run, upgrade test, install guide.

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
