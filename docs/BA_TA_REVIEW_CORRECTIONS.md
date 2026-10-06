# Corrections to "Architecture Design — LINE OA × Salesforce Managed Package" (TA Review, 7 Oct 2026)

**For:** the BA who wrote the TA review document, before it goes to the TA on 7 October.
**Source of truth:** the project specification in this repo (`docs/01`–`09`) and `docs/DECISIONS.md`. Where the review
document and the specification disagree, the specification wins, and the document should be changed to match it,
unless the business wants to change the specification, in which case that becomes a decision (section B).

Checked on 28 September 2026 against the specification and the code as built (Beta 3, version 0.1.0.3).

**Applied (2026-10-04):** the BA's revised .docx was checked again and these corrections were made in it as Word tracked
changes with comments, author "Chaipitch Wongwangpaisarn" (239 insertions, 320 deletions, 8 comments). The file is
`LINE_OA_Salesforce_Architecture_Design_TA_Review_corrected.docx`, sent to the user (not in this repo).

---

## Summary

The document gets the overall shape right: one OA per rep, one webhook endpoint per org, signature verification before
anything else, asynchronous processing, messages stored per bubble, one daily Event as a summary, push for replies,
and no secrets hard-coded in the package.

It conflicts with the specification in nine places (**section A**). Three of them would give the TA a wrong picture of
the security design:

- **Named Credentials and stored access tokens.** The package uses neither.
- **An AI summary and sentiment feature** on the data model page. The specification forbids AI services.
- **Logging rejected webhooks.** The package deliberately logs nothing for rejected requests.

It also presents a **quota-enforcement feature as agreed design**. It is not in the plan (**section B**). This needs
a business decision before the review, not a wording fix.

The rest is field names and values that differ from the agreed schema (**section C**), plus the empty *Component*
column in section 6, filled in below (**section D**).

---

## A. Conflicts with the specification (must fix)

### A1. Credentials: no Named Credentials, no stored access tokens

**Where:** page 1 diagram ("Line Integration Services (Named Credential)", "Tokens stored securely"), 2.4 *Credential
Reference* field, 2.9, 2.10, 3.2 step 4, 3.6, 5.1, 5.2, 5.4, 6 (*Admin UI: enter secret/token*).

**The design (02 D4):**
- Each OA's **Channel Secret** is stored in a **protected custom setting** (`LINE_OA_Credential__c`). Subscriber admins,
  the API and SOQL cannot read it. This has been verified in a real install.
- **Channel access tokens are never stored.** For each transaction, the package issues a short-lived *stateless* token
  (about 15 minutes) from the Channel ID and secret (`POST /oauth2/v3/token`), uses it, and discards it.
- Callouts go through two packaged **Remote Site Settings** (`api.line.me`, `api-data.line.me`), and Apex sets the
  `Authorization` header itself.
- **No Named Credentials.** Named Credentials would need one credential per OA, created by the subscriber as metadata
  every time a rep is onboarded. With the chosen design, registering an OA is one form in the LINE Admin page and
  needs no metadata.

**Corrections:**
- Remove *Credential Reference* from LINE OA Configuration.
- Replace every "Named Credential / External Credential" with "protected custom setting (secret) and a stateless
  token issued per transaction".
- In 5.4, the admin enters only the **Channel ID, the Channel Secret and the rep**. The package fetches everything else.
- The *Channel Access Token* row in 2.9 becomes: "Not stored. Issued on demand from the Channel ID and secret."
- The *Channel Secret* row in 2.9 no longer needs "exact mechanism requires TA confirmation". The mechanism is decided
  and verified. The TA can still challenge it, but the document should state it.

### A2. Remove the AI / sentiment / Opportunity-update point

**Where:** page 3 data model, *Key Design Point 5*: "Opportunity update … (e.g., AI summary, sentiment)".

The specification bans runtime AI or LLM calls of any kind (CLAUDE.md hard rule 3). Apex calls only `api.line.me` and
`api-data.line.me`; the only other host is LINE's sticker CDN, which the browser uses for sticker pictures (DEC-32).
Updating Opportunities is not in scope either.

**Correction:** delete Key Design Point 5, or move it to *Out of Scope*.

### A3. Rejected webhooks are not logged

**Where:** 3.1 step 4 ("records a technical error"), 3.5 (*Invalid signature*: "Record technical diagnostic
information"; *Unknown destination*: "Log and alert/admin review"), 6.2 ("log security event", "admin alert").

**The design (02 D2):** unknown destination → HTTP **403**; bad or missing signature → HTTP **401**. Nothing is
published, **nothing is logged, and no alert is raised.**

This is deliberate. The endpoint is public, and anyone on the internet can POST to it. If a rejected request wrote a
log record, an attacker could fill the subscriber's data storage by sending junk. The HTTP status is the only output.

**Correction:** "Reject with 403 (unknown OA) or 401 (bad signature). No record is written."

### A4. Events: nightly only, and the Event shape as adopted from 2.8

**Where:** page 1 diagram (the *Public Endpoint* box lists "Update conversation" and "Create/Update Event"; inbound
flow step 6 "Create or update a daily Event"), page 11 diagram step 4, 3.3 step 5, data model "Event (1 per Contact per
day)".

**The design (03 §3 *Event*, milestone M9).** On 29 September 2026 the specification **adopted section 2.8** of this
document for the Event itself (DEC-28), so 2.8 stays as written. What still needs correcting is *when* Events are made
and the Opportunity link:
- The webhook endpoint only verifies the request and publishes a platform event. It does not update conversations or
  create Events. Processing runs afterwards, asynchronously.
- Events are created **only** by the nightly batch (01:00, for the previous day). Section 3.1 step 10 of the document
  already says this. The diagrams contradict it.
- There is one Event per **conversation** per day, as 2.8 says. Because a conversation is one Contact with one OA, a
  Contact who chats with two reps gets **two** Events that day. The page 1 diagram's "1 per Contact per day" is wrong.
- As built (2.8 plus the decisions it left open): `WhoId` = the Contact; a **LINE Conversation lookup** on Event;
  `WhatId` = the Contact's **Account** (blank if none). There is no Opportunity link, because nothing in the schema
  ties a conversation to an Opportunity.
- Subject: `LINE Conversation – <Contact name> – <OA name>`. 2.8 has the Contact name only; the OA name was added so
  that two reps' Events for the same customer on the same day can be told apart. Please add it to 2.8.
- Owner: the conversation owner (the rep). Conversations without a Contact are skipped. The Event shows as *Free*, so
  it never blocks the rep's calendar.
- 2.8 leaves *Activity Date / Start-End* open: it is the day's first to last message. A "day" is midnight to midnight
  in the org's default time zone.
- A rerun rebuilds the same Event from the stored messages and never creates a second one (`LINE_Sync_Key__c` =
  `<conversation Id>:<date>`), as 3.3 step 4 already says.

**Corrections:** remove Event creation from the endpoint and inbound boxes in both diagrams; change "1 per Contact per
day" to "1 per conversation per day"; in 3.3 step 5 replace "Opportunity … otherwise Account/blank" with "`WhatId` = the
Contact's Account, blank if none"; remove the Opportunity relation from 5.4; add the OA name to the subject in 2.8.

### A5. Customers without a Contact: conversations come first

**Where:** 2.5.1, 3.1 steps 6–7, 3.5 *Contact not found*, 6.2 *Unmatched LINE user*.

The document orders it *find Contact → find or create Conversation* and says that when no Contact matches, an
"unmatched-user handling process" runs. The specification does it differently:

1. The **conversation is keyed on OA + LINE user ID** (`Unique_Key__c = <Channel ID>:<LINE user ID>`), **not** on
   Contact + OA. It is created and the message is stored whether or not a Contact exists. `Contact__c` stays blank
   until the conversation is linked.
2. Linking (03 §5, `LineLinkService`), in this order:
   - **Auto-link:** a Contact whose `LINE_User_Id__c` matches is linked immediately.
   - **Auto-create** (DEC-27, on by default): on the customer's **first message**, if no Contact holds that LINE user
     ID, a Contact is created, named after their LINE display name and owned by the rep. It is created only when the
     LINE user ID is new, so there are never duplicates.
   - **QR invite code** (M6): the rep shows a QR code; the customer sends the pre-filled code, and the conversation
     links to that Contact.
   - **Manual link** from the rep's inbox (M6).
3. There is no "Unmatched" state or record. An unlinked conversation is simply one with a blank `Contact__c`, and with
   auto-create on it is short-lived.

**The one-Provider requirement.** The document says the design should "avoid assuming that one LINE User ID is globally
sufficient". The specification does assume it (02 D5): **all of a client's OAs must sit under one LINE Provider**. LINE
gives a customer the same user ID in every OA under the same Provider, and a different one across Providers. This is
a setup requirement for each client and should be stated in the document. Whether the ID really is the same across OAs
is an open [VERIFY] item, to be tested in M6 with a second OA.

**Corrections:** reorder the flow to *resolve OA → find or create conversation (OA + LINE user) → store message →
link Contact*; replace "unmatched-user process" with the linking rules above; add the one-Provider requirement.

### A6. The OA used for a reply comes from the conversation, not from the user

**Where:** 2.10 ("Identify current Salesforce User → Find active LINE OA Configuration"), 3.2 step 2 ("the current
Sales Rep has one active LINE OA Configuration").

**The design:** the rep replies *in a conversation*, and the reply goes out through **that conversation's OA**. The
server checks, in user mode, that the rep can see the conversation, then sends through its OA. The browser never
passes an OA or a credential. This satisfies the document's own rule in 5.2 ("never trust client-passed
credential/OA").

This matters because:
- A Contact who chats with two reps has two conversations, and the panel shows one tab per OA.
- A fallback owner, or a manager (still open question 5 in `08`), may reply in a conversation whose OA is not theirs.

**Correction:** "Resolve the OA from the conversation being replied to; check the rep's access to that conversation."

"One active OA per rep" (the *Phase 1 Operational Rule* in 2.2) can stay as a business rule. The package does not
enforce it and does not depend on it.

### A7. The chat panel polls; it does not stream

**Where:** page 1 diagram, *Chat Panel (LWC)*: "Real-time refresh (Platform Event / Streaming)".

**The design (02 D7):** the panel polls every few seconds (a setting), and only while the browser tab is visible.
Streaming counts every delivery to every open tab against the subscriber's daily event allocation, which the package
cannot control. Instant alerts use **Custom Notifications**.

**Correction:** "Refresh by polling (default 5 s, while visible); instant alerts by custom notification."

### A8. Message statuses: no Delivered, Read or Blocked

**Where:** page 3 diagram (*Status: Sent / Delivered / Read / Failed / Blocked*), 2.7, 3.2 step 6.

**The schema (03 §3):** `Received, Sent, Failed, Downloading, Download Failed, Too Large`.

- LINE does not report delivery or read receipts for messages an OA sends, so *Delivered* and *Read* cannot be filled.
- *Blocked* exists only if the quota-enforcement feature is approved (section B). Adding a picklist value to a
  released package is permanent.

**Correction:** use the six schema values. Show *Blocked* only as part of the section B proposal.

### A9. Remove IP allowlisting from the diagram

**Where:** page 1 diagram, *Authentication & Security*: "Optional: IP allowlisting (if supported)".

This contradicts the document's own 5.2 and 5.3, which correctly say LINE does not publish webhook source IPs.

**Correction:** delete the line.

---

## B. Quota enforcement: decided 2026-10-03, display only (DEC-35)

**Decision:** the package shows each OA's usage and allowance (M8a) and does **not** block sending. Section 4 of the
document should be marked "not adopted", or reduced to the display. The analysis below is kept for the record.

**Where:** 2.4 (*Enforce Free Quota*, *Free Quota Threshold*), 2.9, 2.13, 3.2 step 3, 3.2.2, 3.4, section 4 in full,
6 (*quota toggle*).

The document presents a per-OA switch that **blocks outgoing messages** once a threshold is reached, with five new
fields, a *Blocked - Free Quota* status and a fail-closed policy. **None of this is in the agreed plan.** The plan
(06 M8, updated 24 September 2026) is:

| Step | What | Status |
|---|---|---|
| M8a | Admin page shows each OA's usage and allowance, fetched live | Planned, no schema change |
| M8b | Store quota on the OA record, refreshed nightly, for reports and alerts | Needs a decision: permanent packaged fields |
| M8c | Warn the rep in the chat panel when near the limit | Depends on M8b |

The plan **shows** quota; it never **blocks** sending.

What exists today: if LINE itself refuses a push because the monthly limit is reached, the message is stored as
*Failed*, and LINE's own error ("monthly limit") appears on the rep's failed bubble.

**Options:**
1. **Keep the plan.** In the document, label section 4 "Proposed extension — not in the agreed design" so the TA
   doesn't treat it as decided.
2. **Adopt enforcement.** That is a specification change: new fields on `LINE_OA_Configuration__c`, a new *Blocked*
   status value, and a decision record. All of these are permanent once released.

If option 2 is chosen, three points to settle first:
- **LINE already reports each OA's allowance.** `GET /v2/bot/message/quota` returns it (our test OA returned
  `limited 300`). A separate *Free_Message_Limit__c* is therefore only needed as a safety **buffer** below LINE's own
  number, and should be defined that way.
- **Remove the plan table from the diagram.** It shows *Light 500 / Standard 15,000 / Advanced 45,000*. Plan names and
  allowances differ by country and change over time. The package should read the real allowance from LINE, and the
  document shouldn't print numbers that will go stale.
- **Fail-closed vs fail-open** when the quota API is down is a business call, not a technical one, and belongs with
  the business owner.

---

## C. Field corrections (agreed schema, 03 §3)

### LINE OA Configuration (`LINE_OA_Configuration__c`)

| Document says | Schema | Correction |
|---|---|---|
| Owner (User) | `Assigned_Rep__c` Lookup(User) | The *owner* of the record is the admin who registered it. The rep is `Assigned_Rep__c`. |
| LINE OA Name | `Name` | Filled automatically from LINE's bot info |
| LINE Bot / Destination ID | `Bot_User_Id__c` | Filled automatically from LINE's bot info, not entered by the admin |
| Status (Active / Inactive) | `Is_Active__c` Checkbox | Checkbox, not a picklist. An inactive OA sends new conversations to the fallback owner, and its webhooks are still accepted. |
| Credential Reference | — | Remove (A1) |
| Enforce Free Quota, Free Quota Limit/Threshold | — | Not in the schema (section B) |
| Last Connection Check | `Last_Verified_At__c` | Rename |
| *(missing)* | `Basic_Id__c`, `Picture_Url__c`, `Webhook_Status__c` | Add |

Field history is tracked on `Assigned_Rep__c`, `Is_Active__c` and `Webhook_Status__c` (DEC-22).

### Contact

| Document says | Schema | Correction |
|---|---|---|
| LINE User ID | `LINE_User_Id__c` (unique) | ✓ |
| Assigned LINE OA | `LINE_OA_Configuration__c` | This is the Contact's **primary** OA: the one whose chat opens first. It is set when the Contact is first linked. It does not track "currently handled by". |
| Last LINE Message Date | — | Remove. This is on the conversation (`Last_Message_At__c`). |
| LINE Connection Status | — | Remove. Whether a Contact is linked is shown by whether a conversation points to it. |
| *(missing)* | `LINE_Invite_Code__c`, `LINE_Invite_Expires_At__c` | Add (QR invite, M6) |

### LINE Conversation (`LINE_Conversation__c`)

| Document says | Schema | Correction |
|---|---|---|
| Contact | `Contact__c` | **Optional**: blank until linked (A5) |
| Status (Open / Closed) | `Status__c`: **Following / Unfollowed** | Follows whether the customer still follows the OA. There is no open/closed state. |
| Last Message Date | `Last_Message_At__c` | ✓ |
| Last Message By | — | Remove |
| Total Messages (roll-up) | — | Remove |
| *(missing)* | `LINE_User_Id__c`, `Unique_Key__c`, `Picture_Url__c`, `Last_Message_Preview__c`, `Unread_Count__c` | Add. `Unique_Key__c` is what makes one conversation per customer per OA. |

Sharing: **Private**, owned by the rep (or the fallback owner). Managers see conversations through the role hierarchy.

### LINE Message (`LINE_Message__c`)

| Document says | Schema | Correction |
|---|---|---|
| Conversation: Lookup | **Master-detail** | Access to a message follows access to its conversation |
| LINE Message ID as the duplicate key | `Webhook_Event_Id__c` is the duplicate key | `Line_Message_Id__c` is stored too, but duplicates are detected on LINE's **webhook event** ID, which also covers events that carry no message |
| Message Type | `text, image, video, audio, file, sticker, location, unsupported` | Use the full list |
| Status | See A8 | |
| Sent By | `Sender__c` | ✓ |
| Error Information | `Error__c` | ✓ |

### Settings: a custom setting, not Custom Metadata

**Where:** 2.9 (*Package-level static defaults: Custom Metadata*), 5.4 (*Custom Metadata default records*).

Package settings live in a **hierarchy custom setting**, `LINE_Settings__c`, with the defaults written in code. The
admin edits it on the LINE Admin page: site URL, fallback owner, poll interval, retention, invite expiry, daily sync,
Contact owner on reassignment, and auto-create Contact. No Custom Metadata records ship.

---

## D. Section 6: the empty *Component* column

✅ built · 🔜 planned (milestone)

| Layer | Component |
|---|---|
| Inbound API | ✅ `LineWebhookResource` (the only `global` class) |
| Security | ✅ `LineSignatureVerifier` (constant-time HMAC compare), `LineCredentialStore` (the only code that reads the secret) |
| Routing / Config | ✅ `LineOAConfigSelector` (destination → OA), `LineSettings` |
| Identity | ✅ `LineLinkService`: auto-link and auto-create. 🔜 invite codes and manual link (M6) |
| Business processing | ✅ `LineInboundService`, run by `LineWebhookEventTrigger` → `LineWebhookEventTriggerHandler` |
| Outbound API | ✅ `LineApiClient` (every HTTP call to LINE), `LineOutboundService` (send, then record) |
| Activity | 🔜 `LineDailyEventSyncBatch` (M9) |
| Async | ✅ platform event `LINE_Webhook_Event__e`, `LineCalloutQueueable` |
| Scheduled | 🔜 `LineScheduler`: daily Events and retention (M9–M10) |
| Notification | ✅ custom notification `LINE_New_Message`; `Unread_Count__c` on the conversation |
| UI | ✅ `lineChat` + `LineChatController`. 🔜 `lineInbox`, `lineInvite` (M6) |
| Admin UI | ✅ `lineAdmin` + `LineAdminController` + `LineOAConfigAdminService` (settings, register OA). 🔜 rotate secret, reassign, deactivate, quota, error log (M8) |
| Logging | ✅ `LineLogger` → `LINE_Error_Log__c`: source, message, stack trace, OA, related record, HTTP status. Secrets and tokens are masked. **Errors only**: there are no API call logs or quota usage logs (the page 1 diagram lists both). |

Also remove *Retry failed messages* from the *Scheduled Job* box on page 1. Failed sends are **not** retried
automatically, because retrying a send risks messaging the customer twice. The rep sees the failure and decides.
Transient network retries are handled safely by LINE's `X-Line-Retry-Key`.

---

## E. Permission sets

| Document says | Package (03 §6) |
|---|---|
| LINE Integration Admin | `LINE_Admin`, plus custom permission `LINE_Admin`, which every admin action checks |
| LINE Integration User | `LINE_Chat_User` |
| Webhook Guest Access | `LINE_Webhook_Guest`: the webhook Apex class and Create on the platform event (plus the Read that Salesforce requires alongside Create), **nothing else** |

Reps can create messages but **cannot edit** them, so sent history cannot be rewritten. Nobody can create
conversations by hand; only inbound processing creates them (DEC-13).

---

## F. Section 5.4 (provisioning), corrected

| Ships with the package | Subscriber sets up after install |
|---|---|
| Apex, trigger, queueable, (M9) scheduled batch | A **Salesforce Site** for the webhook (*Setup → Sites*) |
| `lineChat`, `lineAdmin` | Permission sets: `LINE_Webhook_Guest` on the Site guest user; `LINE_Admin`, `LINE_Chat_User` on people |
| Objects, fields, platform event, protected setting, settings | LINE Admin page: site URL and fallback owner |
| Permission sets, custom permission, custom notification | Per OA: **Channel ID, Channel Secret, rep**. Nothing else. |
| Remote Site Settings for the two LINE hosts | **Add `lineChat` to the Contact record page** (pages are never auto-activated) |
| Custom Labels in English and Thai | In the LINE Developers Console: **"Use webhook" ON** (Messaging API tab) |
| `LINE_Sync_Key__c` on Event | |

Remove from the table: *Bot User ID, Provider ID* (fetched automatically or not needed), *Channel Access Token /
External Credential principal* (A1), *Custom Metadata default records* (section C), *Named Credential template* (A1),
*Opportunity relation* (A4).

The package also **sets the webhook URL in LINE automatically** when an OA is registered. The admin never pastes it
into the LINE Developers Console. They do have to switch *Use webhook* on there: while it is off, the console's
*Verify* button still succeeds but no message ever arrives, as the first QA install found on 24 September 2026.

---

## G. Already aligned (no change needed)

- Executive summary: a real-time chat store, a daily Event summary, and replies that never go through the batch.
- The three-way split of business data, configuration and secrets (2.1).
- Signature verified over the **raw** body, before anything else; the destination used only to pick which secret to
  check with (3.1 steps 2–4).
- Fast acknowledgement, asynchronous processing, duplicate-safe (5.3).
- Reply API vs Push API (3.2.1): replies from Salesforce use **push**, because reply tokens expire within about a
  minute.
- No token or secret ever reaches the browser (3.6, 5.2).
- The guest user gets the minimum: one Apex class and no object read (5.3).
- The rule that Event failures must never roll back a stored message (6.2). The specification goes further: **no
  Contact or Event failure may ever cost a message**, because the subscriber's validation rules are unknown.
- Appendix A shows the real `lineChat` panel.

---

## H. Open questions to settle before 7 October

| # | Question | Where it is tracked |
|---|---|---|
| 1 | Quota **enforcement** (block sending), or quota **display** only? | Section B; `08` open question 7 |
| 2 | Can managers reply on behalf of a rep, or only read? | `08` business question 5 |
| 3 | Should the package **enforce** one active OA per rep, or leave it as an operational rule? | Not tracked yet; new |
| 4 | Are Opportunity links wanted in a later phase? `WhatId` now holds the Account (DEC-28), and nothing links a conversation to an Opportunity. | `08` business question 9 |
| 5 | Can reps also reply from the LINE OA Manager app? Those replies never reach Salesforce. | `08` L1; `LINE_API_OA_MANAGER_LIMITATION.md` |
