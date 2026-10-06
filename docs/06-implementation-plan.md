# 06 — MVP Implementation Plan

Work **milestone by milestone**. Each milestone ends deployed to a scratch org with its tests green. Claude stops after each one for review.
Estimates are person-days of development effort.

Milestones M3, M6 and M11 each end with a **beta package version installed in the QA org**, so packaging problems show up early, not at the end.
In practice betas are built whenever the QA org needs something new, and numbered by build (`0.1.0.N`), not by milestone.

**Status on 2026-09-29** (details in `HANDOFF.md`): M0–M5 done; M6 part done (auto-link, auto-create Contact); M8 part done
(settings, OA registration, nightly jobs); M9 done and live in the QA org on Beta 4; sticker pictures (part of M7, DEC-32)
built on 2026-09-30.

| # | Milestone | Est. | Status |
|---|---|---|---|
| M0 | Packaging foundation | 2–3 | ✅ |
| M1 | Data model, settings, security metadata | 2–3 | ✅ |
| M2 | Core services: logger, settings, credential store, LINE API client | 2–3 | ✅ |
| M3 | OA registration + inbound webhook + processing → **Beta 1** | 4–5 | ✅ |
| M4 | Outbound text | 1.5–2 | ✅ |
| M5 | Chat panel (`lineChat`) | 4–5 | ✅ |
| M6 | Linking: manual, auto, QR invite + inbox (`lineInbox`) → **Beta 2** | 5–6 | Part: auto-link, auto-create (DEC-27) |
| M7 | Files and images, in and out | 5–7 | Part: sticker pictures (DEC-32) |
| M8 | Admin UI (`lineAdmin`) + reassignment batch | 4–5 | Part: settings, register OA, nightly jobs, remove OA + credentials check (DEC-25, DEC-29, DEC-33) |
| M9 | Daily Event sync | 2–3 | ✅ live in the QA org (Beta 4) |
| M10 | Retention + error log housekeeping | 1.5–2 | |
| M11 | Hardening: security review readiness, EN/TH labels, LDV test → **Release candidate** | 4–5 | |
| M12 | QA org end-to-end, upgrade test, install guide, UAT support | 3–5 | |
| | **MVP total** | **40–54 d** (+15–20% contingency) | |

---

## M0 — Packaging foundation (2–3 d)
- [HUMAN] 05 Part A1–A5 (Dev Hub, namespace, link, auth).
- [CLAUDE] Set up `sfdx-project.json` (namespace, package dir, `unpackaged/`), the scratch definition, and `scripts/setup-scratch.sh`
  (create scratch → deploy → assign permission sets → create 2 test rep users → seed settings).
- [CLAUDE] `sf package create`. Create an empty beta version to prove the pipeline, and install it into the QA org.
- [CLAUDE] Create `docs/DECISIONS.md` and `docs/SECURITY_NOTES.md`. Add a Code Analyzer run script.

**Done when:** a scratch org is created by one script; an empty beta installs into the QA org.

> **Order change (DECISIONS DEC-08):** M1–M5 were built first in non-namespaced scratch orgs from `sf-line-dev`, then moved to a
> namespaced one when `tsthlineoa` was linked (2026-09-22). The first beta was built after M5, not at M3.

## M1 — Data model & security metadata (2–3 d)
Everything in 03: the 3 custom objects, Contact/Event fields, `LINE_Webhook_Event__e`, `LINE_OA_Credential__c` (protected),
`LINE_Settings__c`, `LINE_Error_Log__c`, custom permission, CustomNotificationType, remote site settings, the 3 permission sets,
the app and tabs, and a label skeleton. Include descriptions on every object and field.

**Done when:** deploys to a scratch org; permission sets match 03 §6; a beta version builds (no code yet → coverage not required).

## M2 — Core services (2–3 d)
`LineTriggerHandler` (base), `LineLogger`, `LineSettings`, `LineNamespace`, `LineCredentialStore`, `LineApiClient` (+ `LineApiException`,
typed DTOs), `LineHttpMock`, and `LineTestFactory`.

**Done when:** unit tests cover every `LineApiClient` method, including error mapping (400/401/403/409/429/5xx).

## M3 — Registration + inbound (4–5 d) → Beta 1
- `LineOAConfigSelector`, `LineOAConfigAdminService.registerOA` (anonymous-Apex callable at this stage).
- `LineSignatureVerifier`, `LineWebhookResource`, `LineWebhookEventTrigger` + handler, `LineInboundService` (text + follow/unfollow;
  store other types as placeholders), and a `LineCalloutQueueable` profile fetch.
- Notifications to the owner.
- **Beta 1** → QA org: create the Site, assign the guest permission set, register 2 real OAs, send from phones.

**Done when:** acceptance criteria 1 (inbound half), 3 and 4 pass in the QA org; a wrong signature returns 401; redelivery doesn't duplicate.
Record the [VERIFY] results for stateless tokens, `destination`, and Automated Process notifications/callouts.

## M4 — Outbound text (1.5–2 d)
`LineOutboundService.sendText`, `LineChatController.sendText` (user-mode access check, 1–5000 chars), and failure status/error mapping.

**Done when:** a send from a scratch org test passes; a mocked 429 monthly-limit error gives a readable message.

## M5 — Chat panel `lineChat` (4–5 d)
- Controller: `getConversations(contactId)` (default to the Contact's primary OA), `getMessages(conversationId, beforeSentAt, beforeId, pageSize)`,
  `getMessagesSince(conversationId, afterSentAt, afterId)`, `markRead`.
- UI:
  - bubbles, time in the user's time zone, failed state, placeholders for non-text;
  - load older on scroll-up; poll while visible; send on Enter (Shift+Enter for a newline);
  - empty state with an *Invite via LINE* button (wired in M6). All labels EN/TH.
- Jest tests.

**Done when:** acceptance criteria 1–2 (text) pass in a scratch org with simulated inbound events.

## M6 — Linking + inbox (5–6 d) → Beta 2
- `LineLinkService`: manual, auto, and invite code (03 §5); `createInvite`; confirmation/expired **reply** in the queueable.
- `lineInvite` modal: QR (static resource library), copy link, expiry shown.
- `lineInbox`: tabs *Unread* and *Unlinked*, link to Contact (`lightning-record-picker`), open the conversation.
- **Beta 2** → QA org: scan the QR with a real phone; add a second OA and check it auto-links.

**Done when:** acceptance criteria 6 passes on real phones (iOS and Android); the URL scheme result is recorded in DECISIONS.

## M7 — Files & images (5–7 d)
- **Done early (DEC-32):** inbound stickers show as their picture from LINE's sticker CDN, with a `[Sticker]` fallback.
- Inbound: download content in `LineCalloutQueueable` (size check → Too Large; one large file per execution; chain the rest),
  ContentVersion with `FirstPublishLocationId` = conversation, and a ContentDocumentLink to the Contact if linked. Thumbnails and download links in `lineChat`.
- Outbound: upload in `lineChat` → image/video/audio sent natively, other files as an expiring `ContentDistribution` link in a text message.
  Validate type and size before the callout.
- Stickers rendered as a label or image (as verified), location as a text + map link.

**Done when:** acceptance criteria 2 (image + document) and 7 pass in the QA org with real files; LINE accepts the Salesforce public URL (recorded in DECISIONS).

## M8 — Admin UI + reassignment (4–5 d)
- `lineAdmin` app page:
  - **Settings form** for `LINE_Settings__c`;
  - **OA list** with register, rotate secret, reassign, deactivate/activate, test webhook and quota;
  - **Job status**, with schedule/unschedule of the nightly jobs;
  - **Error log** list.
- `LineAdminController` checks the `LINE_Admin` custom permission.
- `LineOAConfigTriggerHandler` → `LineReassignBatch` (optional Contact Owner update).
- **Secret cleanup** (agreed 2026-10-03, DEC-33; ✅ **built ahead of M8, Beta 6**). The protected setting is unreachable for subscriber admins, so
  the package must offer the only way out:
  - **Remove OA** on the LINE Admin page: deletes the channel secret, keeps the OA record and its conversations as inactive.
  - **Nightly credentials check** in `LineScheduler`: issue a token per active OA; when LINE rejects the credentials (channel
    deleted or secret reissued), flag the OA on the admin page. Never delete automatically.
  - **Safety net:** deleting an OA record by any route deletes its secret (`LineOAConfigTrigger`, after delete).
- **Message quota per OA** (L2). `LineApiClient.getQuota()` and `getQuotaConsumption()` already exist and are
  unused outside the smoke-test script; this is the first place they reach a user.
  - **M8a (do first, no schema commitment):** a *Quota* column on the OA table — `used / allowance` with the
    remainder, fetched live on demand, admin only. `type = "none"` means an unlimited plan and shows as such.
    Two callouts per OA, so refresh is a button, never a page-load or a poll.
  - **Decided 2026-10-03 (DEC-35): display only.** No blocking of sends.
  - **M8b (optional, needs a decision first):** store `Quota_Limit__c`, `Quota_Used__c` and `Quota_Checked_At__c` on
    `LINE_OA_Configuration__c`, refreshed by the nightly scheduler (M9), so quota can be reported and alerted on.
    Packaged fields are permanent (09 §4), so this needs a `DECISIONS.md` entry and a schema change to 03 §3.
  - **M8c (optional, decide with M8b):** warn the rep in `lineChat` when their OA is near its limit. More useful
    than a number on a page an admin rarely opens, but it needs the stored fields — reps must not trigger callouts.
  - Salesforce replies are **push** messages and always count against the quota; LINE's *reply* messages don't, but
    reply tokens are single-use and short-lived, so the package cannot rely on them (04 §3, L2).

**Done when:** acceptance criterion 5 passes; OA onboarding is done entirely in the UI; no secret outlives its OA's
removal; an admin can see how many
messages each OA has left this month without leaving Salesforce.

## M9 — Daily Event sync (2–3 d)
`LineDailyEventSyncBatch` per 03 §3 Event; `LineScheduler` runs it nightly (plus retention). Idempotent by `LINE_Sync_Key__c`.
Partial-success DML with logging.
- Event shape follows the TA review document §2.8 (DEC-28): new lookup `Event.LINE_Conversation__c`, `WhatId` = Account.
- **Pulled forward from M8** (DEC-29): the *Nightly jobs* card on the LINE Admin page — status, **Schedule**,
  **Unschedule**, **Sync today now**. A subscriber cannot schedule a non-global class any other way.

**Done when:** acceptance criterion 8 passes, including a rerun and an org with a validation rule on Event (test).

## M10 — Retention (1.5–2 d)
`LineRetentionBatch`: delete messages older than `Message_Retention_Months__c`, and their ContentDocuments; delete error logs older than 90 days.
0 = off.

**Done when:** tests cover the boundary dates and the file deletion.

## M11 — Hardening → release candidate (4–5 d)
- Code Analyzer clean (no Critical/High); CRUD/FLS review; fill in `SECURITY_NOTES.md`.
- Thai translations for all labels (have a native speaker review them).
- LDV check in a scratch org: load 200k messages across 500 conversations with a script. Check message paging, poll query and batch times,
  and record the numbers in DECISIONS.
- Coverage ≥ 85% overall, every class ≥ 75%.
- **Evaluate a Named Credential as the callout endpoint** (08 risk "Callout allowlist"). Today packaged Remote Site Settings
  allowlist `api.line.me` and `api-data.line.me`, and Apex sets the per-OA token itself (D4). Option: a packaged Named
  Credential with **no authentication**, used only as the endpoint (`callout:…`), Apex still setting the `Authorization`
  header. Prove first, in an installed package: callout access through the External Credential's principal (permission
  set) for reps, admins **and the Automated Process user** that runs inbound follow-up callouts. Adopt only if it works
  with no extra subscriber setup; record the outcome in DECISIONS.
- A beta version with `--code-coverage` → QA.

## M12 — QA, upgrade, docs (3–5 d)
- Full acceptance run (01 §4) in the QA org on real phones.
- **Upgrade test**: previous beta → uninstall → install RC; later, released → next version upgrade.
- `docs/INSTALL_GUIDE.md` (from 05 Part C/D/E, with screenshots) and `docs/RELEASE_NOTES.md`.
- Promote only when the user approves.

## After MVP (backlog)
Person Account support, Pattern 1 (shared OA), LMA licensing, AppExchange security review submission, `unsend` event handling,
rich messages (Flex) for document links, a message search/report pack.
