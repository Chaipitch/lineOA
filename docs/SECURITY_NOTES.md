# Security Notes

This file becomes the AppExchange security review submission (09 §7). Keep it current as each milestone lands.
Status per section: what is designed (from the spec) and what is **implemented and tested** (filled in as we build).

## 1. External endpoints

| Host | Purpose | Remote Site Setting | Implemented |
|---|---|---|---|
| `https://api.line.me` | Token, bot info, webhook set/test, profile, push, reply, quota | `LINE_API` | M1/M2 |
| `https://api-data.line.me` | Message content download | `LINE_API_DATA` | M1/M2 |

No other callouts. No AI/LLM services. The QR library is a static resource (`qrcode-generator` 2.0.4, MIT; reviewed: no network,
`eval` or DOM access; draws on a canvas, no `innerHTML`; DEC-42). The invite link `line.me/R/oaMessage/...` is opened by the
customer's phone; Apex never calls it. Invite codes are 8 random characters from a 32-symbol alphabet (40 bits), one-time,
expire after `Invite_Code_Expiry_Days__c` (7), and only link when the conversation's LINE user isn't held by a Contact a person linked.

**Why Remote Site Settings, not Named Credentials (D4, DEC-16):** two fixed hosts, the same for every subscriber, approved
by the admin in the install wizard; authentication is per OA and issued at runtime, so it can't be stored as endpoint
configuration. The base URLs are literals in `LineApiClient` only, HTTPS, never built from user input. A no-authentication
Named Credential as the endpoint is evaluated in M11 and adopted only if it needs no subscriber setup.

**One browser-side load (DEC-32):** `lineChat` shows sticker pictures from `https://stickershop.line-scdn.net`, allowed by the
packaged CSP Trusted Site `LINE_Sticker_Images` for **img-src only** in Lightning Experience. Apex never calls it. The URL is
built server-side (`LineApiClient.stickerImageUrl`) from an all-digit sticker ID, so nothing a customer types can reach it
(tested with path, host and non-digit values). What LINE sees: the viewer's IP address and a sticker ID, no customer data.
If the image fails, the panel shows `[Sticker]`.

## 2. Guest (unauthenticated) surface

- One Site guest user per subscriber org, holding only the `LINE_Webhook_Guest` permission set:
  Apex class `LineWebhookResource` and Create on `LINE_Webhook_Event__e`. No object read access.
- Endpoint: `POST /services/apexrest/<ns>/line/webhook`.
- Order of checks: resolve the OA by `destination` (unknown → 401, DEC-38) → verify `X-Line-Signature`
  (HMAC-SHA256 over the raw body with that OA's channel secret; bad or missing → 401) → publish one platform event per LINE event.
- No business DML and no callouts in the guest context. Processing runs later in the PE trigger as Automated Process.
- The permission set also holds **Read** on `LINE_Webhook_Event__e`, because the platform won't grant Create without it. Read on a
  platform event only allows subscribing, and it grants no record access (DECISIONS DEC-13c, pending approval).

Implemented (M3), tested and verified live with LINE:
- `LINE_Webhook_Guest` = Apex class `LineWebhookResource` + `LINE_Webhook_Event__e` Create/Read. No objects, no fields.
- Input limits before authentication: body ≤ 1 MB, and only the top-level `destination` is read (streaming parser) to pick the secret.
- Signature: HMAC-SHA256 over the raw body; Base64 compared **case-sensitively in constant time** (`LineSignatureVerifier`). Missing, wrong-case or wrong signatures → 401 (tests).
- **Replay protection (R8):** LINE signatures carry no timestamp, so a captured genuine request could be resent. It does no harm:
  every LINE event is stored by its unique `webhookEventId`, so a replay or redelivery changes nothing and is never processed twice.
- Unknown destination → 401, the same as a bad signature, so registered OAs can't be enumerated (DEC-38); malformed → 400; nothing is published or stored in any rejected case (tests).
- The webhook writes no records at all, not even error logs, so unauthenticated traffic can't create data. Its only output after authentication is `EventBus.publish`.
- Code Analyzer's graph engine flags the system-mode OA lookup on this path (High). It is suppressed at `LineOAConfigSelector.byBotUserIds` with the reason above (DECISIONS DEC-18).

## 3. Secret storage

- Channel secrets: protected list custom setting `LINE_OA_Credential__c` (Name = Channel ID, `Channel_Secret__c`).
  Only reachable from package code; only `LineCredentialStore` reads or writes it.
- Access tokens: stateless (~15 min), issued on demand and cached per transaction. Never stored.
- Secrets and tokens never appear in DTOs, LWC, logs, `System.debug`, error messages, tests, scripts or docs.
  Tests use fake values only.

Implemented: M1 — `LINE_OA_Credential__c` is a List custom setting with Visibility **Protected**; no permission set grants access to it.
The protection itself only applies once installed as a managed package. **Verified 2026-09-22 (Beta 1, QA org):** a subscriber
System Administrator querying `tsthlineoa__LINE_OA_Credential__c` gets "sObject type … is not supported" (DECISIONS §2).

**Why a protected custom setting (TA review R7):** checking LINE's webhook signature is an HMAC over the raw body with the
channel secret, so Apex needs the secret itself. A Named Credential never hands its secret to Apex, so it can't serve
here; a protected setting is unreadable to subscriber admins, the API and other code once installed (verified above).

**Procedures (R7, DEC-45):**
- **Rotation:** LINE Developers Console → the channel → Basic settings → issue a new channel secret → straight away, LINE
  Admin → the OA → **Rotate secret** → paste. Salesforce checks it with LINE before storing it; a wrong one changes nothing.
  Messages fail between the two steps (LINE keeps one secret), so do them together; with webhook redelivery on, LINE resends
  what failed [VERIFY].
- **Suspected leak:** rotate immediately (the leaked secret stops working the moment LINE issues the new one), then check
  the OA's sent messages in LINE OA Manager for anything not sent from Salesforce. If the OA is being retired, **Remove** it
  instead, which deletes the secret.
- **Development and test orgs:** never use a production OA's secret in a scratch, development or beta org. The protection
  only applies to an installed managed package; in a source-deployed org the setting is readable. Use test OAs there.
- **Audit:** credential status changes are field-history tracked (`Credential_Status__c`), as are the assigned rep, active
  flag and webhook status (R17).

Implemented: M2
- `LineCredentialStore` is the only class that references `LINE_OA_Credential__c`. It validates the channel ID (digits, at most 38 characters) and secret, and its errors never echo the value (tested).
- `LineApiClient` keeps the secret in a private `transient` field, sends it only in the token request body (URL-encoded), and never includes the request in errors.
- The token is only in the `Authorization` header and the per-transaction cache; no DTO or return value outside `issueToken()` carries it.
- `LineLogger` masks bearer tokens, `client_secret=…` and `access_token`/`channelSecret` JSON values before writing (tested).

Implemented (DEC-33, Beta 6): **secrets don't outlive their OA.** Subscriber admins can't see or delete the protected
setting, and LINE sends no event when a channel is deleted, so the package provides the way out:
- **Remove OA** (admin page, `LINE_Admin` custom permission) deletes the secret and keeps the OA as inactive *Removed*.
- Deleting an OA record by any route deletes its secret (`LineOAConfigTrigger`, after delete, bulk).
- A **nightly credentials check** marks an OA *Rejected* when LINE refuses its credentials, so dead secrets are visible.
  An outage never counts as a rejection, and nothing is deleted automatically.

## 4. `without sharing` classes (justification)

From 02 §2. Each class carries a justification comment in code. Filled in as each class is built.

| Class | Why system mode | Implemented |
|---|---|---|
| `LineWebhookResource` | Guest context; must look up the OA by `destination` without granting the guest read access | ✅ M3 |
| `LineCredentialStore` | Reads the protected custom setting | ✅ M2 (justification comment in class; DML uses explicit `AccessLevel.SYSTEM_MODE`) |
| `LineOAConfigSelector` | Used from the webhook and the PE trigger, which have no user context | ✅ M3 (queries use `WITH SYSTEM_MODE` explicitly) |
| `LineWebhookEventTriggerHandler` | PE trigger runs as Automated Process | ✅ M3 |
| `LineInboundService` (+ inner `OwnerResolver`) | Creates conversations/messages owned by reps, from system context | ✅ M3 (DML uses `AccessLevel.SYSTEM_MODE`) |
| `LineCalloutQueueable` | Async follow-up; updates conversations and OA configurations the running user may not own | ✅ M3 |
| `LineOAConfigAdminService` | Writes the secret and OA configurations; the caller (`LineAdminController`) checks the `LINE_Admin` custom permission first | ✅ M3; admin page since DEC-25 |
| `LineLinkService` | Links and creates Contacts from the inbound path (Automated Process). Manual link: `LineChatController.linkToContact` first checks, as the user, read on the conversation and Edit on the chosen Contact (`UserRecordAccess`); the service then moves the LINE user ID off an **auto-created** placeholder (never off a Contact a person linked) and deletes that placeholder only if nothing else is attached (DEC-34), which the rep may not own. Unlink is admin-only (`LINE_Admin`). | ✅ M6 (auto-link, auto-create, manual link, unlink; DEC-27, DEC-34, DEC-41) |
| `LineOAConfigTriggerHandler` | Deletes the protected secrets of deleted OAs for whoever deleted them; the setting is reachable only from package code | ✅ Beta 6 (DEC-33) |
| `LineDailyEventSyncBatch` | Runs as whichever admin scheduled it, possibly for years; must see every conversation whatever that admin's sharing is. Writes Events owned by reps; nothing is shown to a user | ✅ M9 (DEC-30; queries `WITH SYSTEM_MODE`, DML `AccessLevel.SYSTEM_MODE`, partial success) |
| `LineOAStatsBatch` | Runs as whichever admin scheduled the nightly job; must count every conversation whatever that admin's sharing is. Writes only counts on OA records; reads no message content (aggregate `COUNT` only) | ✅ 0.4.0 (DEC-49; queries `WITH SYSTEM_MODE`, update `AccessLevel.SYSTEM_MODE` partial-success and logged) |
| Send authorization (DEC-37) | `LineChatController.assertCanSend`: seeing a conversation is not enough; only the OA's assigned rep (inactive OA: fallback owner or fallback-queue member) may send. OA routing fields read in system mode so OA sharing can't widen who may send | ✅ |
| `LineOutboundService` | Called after the controller checks access in user mode; writes the message record | ✅ M4 (class-wide `sfge` suppression with reason, DEC-20) |
| `LineOAConfigTriggerHandler` | Starts the reassignment batch | M8 |

## 5. CRUD/FLS and sharing

- User-facing Apex (`LineChatController`, `LineAdminController`) is `with sharing` and uses `WITH USER_MODE` / `AccessLevel.USER_MODE`.
- `LineAdminController` also checks the `LINE_Admin` custom permission.
- `LINE_Conversation__c` OWD Private (owner = the OA's rep); `LINE_Message__c` is master-detail (Controlled by Parent).

Implemented (M1):
- `LINE_Conversation__c` OWD Private (internal and external); `LINE_Message__c` Controlled by Parent; `LINE_OA_Configuration__c` Public Read Only; `LINE_Error_Log__c` Private.
- `LINE_Chat_User`: conversations Read/Edit (FLS edit only on `Contact__c`, `Unread_Count__c`); messages Read/Create (FLS read-only, since outbound inserts run in system mode); OA configuration Read; the four Contact LINE fields Read/Edit; `LINE_Sync_Key__c` Read.
- `LINE_Admin`: the above + OA configuration CRUD, View All on conversations and messages, error log Read/Edit/Delete/View All (field-level read-only), custom permission `LINE_Admin`.
- Neither permission set grants access to Contact or Event objects themselves; that stays with the subscriber's profiles.

Implemented (M4): `LineChatController` is `with sharing`; `sendText` queries the conversation `WITH USER_MODE` (so OWD Private
decides who may reply) and checks `LINE_Message__c.isCreateable()` before any callout. Tests prove Rep B cannot send to Rep A's
conversation and that nothing is sent or stored when the check fails. Errors reach the LWC as `AuraHandledException` with a
Custom Label; LINE's own wording is passed through only for errors the rep can act on (monthly limit, invalid text).

Implemented (M5): every `LineChatController` read (`getConversations`, `getMessages`, `getMessagesSince`, `markRead`) runs
`WITH USER_MODE`, so a rep only ever sees conversations sharing lets them see; tested with `System.runAs(RepB)`.

Implemented (DEC-25, DEC-29): `LineAdminController` is `with sharing` and every method starts with
`FeatureManagement.checkPermission('LINE_Admin')`; tested by calling each method as a rep. The channel secret goes in
through `registerOA` only, is never returned, and the page's password field is cleared after use. Settings are custom
settings written `as system` after that check. Job status reads `CronTrigger` / `AsyncApexJob` in system mode, which is
job metadata, not business data.

## 6. Client side (LWC)

- Message text is rendered as text, never HTML. Customer links are shown as text, not auto-linked.
- No `innerHTML` with untrusted data. No `console.log`.

Implemented (M5, M8 part): `lineChat` and `lineAdmin` render message text with text bindings only (no `innerHTML`, no
`lwc:dom="manual"`), have no `console.log`, and ESLint passes on every build.

## 7. Outbound public links

- Media and documents are shared through `ContentDistribution` with an expiry (`Public_Link_Expiry_Days__c`).

Implemented (M7, DEC-43): a public link is created only for a File the rep uploaded to that conversation (checked by
`ContentDocumentLink`), only by a user who may send in it (DEC-37) and can see the File (user mode); it expires after
`Public_Link_Expiry_Days__c` (7), no password, view and download allowed. Anyone holding the link can open the file until then,
which is inherent to sending it over LINE; the rep chooses what to upload. Inbound files are stored as Salesforce Files only
(never rendered as HTML or executed); file names come from the customer and are used only as the File's title.

## 8. Code Analyzer

Run: `npm run scan` (Recommended + Security + AppExchange rules, fails on High/Critical). The Flow engine is disabled because the package has no Flows (DECISIONS DEC-06).

| Date | Scope | Critical/High | Notes |
|---|---|---|---|
| 2026-10-20 | `force-app`, full `./scripts/code-analyzer.sh` (0.4.0: per-OA counts, DEC-49) | **46 High, open** | None in the changed files (new class: Low only). Pre-existing, first seen in this full scripted run: 19 `sfge:ApexFlsViolation` (`LineLinkService`, `LineChatController`), 18 `sfge:DatabaseOperationsMustUseWithSharing` (`LineLinkService`, `LineDailyEventSyncBatch`), 9 ESLint in the bundled `qrcode.js`. Released anyway by the user's decision (DEC-50); review before 0.5.0 |
| 2026-10-15 | `force-app` classes + LWC (M6 invite and linking, M7 files, stickers, rotate secret, duplicate-rule fix; releases 0.1.0.10–0.3.0.1) | 0 | ~90 Moderate, ~300 Low: same categories (complexity, ApexDoc, naming); one High (CRUD on `UserRecordAccess`) fixed with `WITH USER_MODE` |
| 2026-10-03 | `force-app` (secret cleanup, credentials check, Event rounding, Beta 6) | 0 | 57 Moderate, 237 Low: no new categories |
| 2026-09-30 | Sticker pictures (`LineApiClient`, `LineChatController`, `lineChat`, CSP Trusted Site) | 0 | No new categories |
| 2026-09-29 | `force-app` (M9 daily sync, nightly jobs) | 0 | 58 Moderate, 212 Low. New Moderate: complexity on `LineDailyEventSyncBatch` and `LineAdminController`, justified in DECISIONS §3 |
| 2026-09-24 | `force-app` (DEC-27 auto-create, Beta 3) | 0 | 51 Moderate, 186 Low: unchanged categories |
| 2026-09-22 | `force-app` (M5, admin page, Beta 1–2) | 0 | Unchanged categories |
| 2026-09-19 | `force-app` (empty, M0) | 0 | Baseline |
| 2026-09-19 | `force-app` (M1 metadata) | 0 | 4 Moderate `ProtectSensitiveData` name-heuristic hits, justified in DECISIONS §3 |
| 2026-09-22 | `force-app` (M4 outbound text) | 0 (5 graph-engine Highs suppressed class-wide on `LineOutboundService` with reason, DEC-20) | 36 Moderate, 165 Low: unchanged categories |
| 2026-09-19 | `force-app` (M3 webhook + inbound) | 0 (2 graph-engine Highs + 1 Moderate suppressed with reasons, DEC-18) | 35 Moderate (complexity/parameter style, DTO naming, name heuristics), 157 Low (ApexDoc on DTO fields/tests) |
| 2026-09-19 | `force-app` (M2 core services) | 0 (1 High suppressed with reason: `ApexSuggestUsingNamedCred`, DEC-16) | 23 Moderate (style/complexity, DTO naming, name heuristics), 90 Low (ApexDoc on DTO fields/tests). All in DECISIONS §3 |
