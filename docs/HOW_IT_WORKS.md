# How LINE Connect works

A tour of the package for a developer who has just cloned this repo: what it does, how a message travels in each
direction, why the pieces are arranged the way they are, and where the rules come from.

The specification is in `01`–`09`; this document is the map that makes those readable. Where the two disagree, the
spec wins and this file is wrong — say so.

---

## 1. The problem

A Thai sales team sells over LINE. Every rep has **their own LINE Official Account** ("OA"), and their customers chat
with that OA from the LINE app on their phone. None of it reaches Salesforce: the conversation lives on the rep's
phone, and when the rep leaves, so does the relationship.

LINE Connect puts that conversation inside Salesforce. A rep opens a Contact, sees the LINE chat history in a panel on
the record page, and replies from there. The customer sees a normal LINE message from the OA they already follow.

Three facts shape the entire design:

1. **One OA per rep, many OAs per org.** Nothing can assume a single set of credentials. Every conversation, message
   and callout is scoped to one OA, and the OA decides who owns the record.
2. **LINE pushes, it does not let us pull.** There is no endpoint that reads a conversation. We only ever learn about
   a message because LINE calls our webhook at the moment it arrives. Miss it and it is gone —
   see [LINE_API_OA_MANAGER_LIMITATION.md](LINE_API_OA_MANAGER_LIMITATION.md).
3. **It ships as a managed package into orgs we have never seen.** We cannot know the subscriber's profiles,
   validation rules, page layouts or required fields, and once a component is released its name and type are
   permanent (`09` §4).

---

## 2. The shape of the system

```
   LINE app  ──►  LINE platform  ──►  [ webhook ]  ─►  Platform event  ─►  [ inbound processing ]  ─►  records
  (customer)                          guest user       LINE_Webhook_        Automated Process          Conversation
                                      no DML           Event__e                                        + Message
                                                                                    │                     │
                                                                                    ▼                     ▼
                                                                             callout queueable      custom notification
                                                                             profile + Contact         to the rep

   Rep in Salesforce  ──►  lineChat LWC  ──►  LineChatController  ──►  LineOutboundService  ──►  LINE  ──►  customer
                                              (user mode)              callout, then DML
```

Two paths, and they are deliberately asymmetric. **Inbound is public and hostile** — anyone on the internet can POST to
the endpoint — so it does as little as possible. **Outbound starts from an authenticated rep** with a session, so it can
check permissions properly and talk to LINE directly.

---

## 3. Inbound: a customer sends a message

### 3.1 The webhook — `LineWebhookResource`

`POST /services/apexrest/<ns>/line/webhook`, exposed through a public **Site**, running as the **Site guest user**.

This is the only `global` class in the package (`@RestResource` demands it, and hard rule 2 forbids `global`
everywhere else). It is also the only code an anonymous internet user can reach, so it is written to be boring:

```
body empty, oversized, or unparsable        → 400
destination is not an OA we know            → 403
X-Line-Signature missing or wrong           → 401
otherwise: publish one platform event per   → 200
LINE event, and nothing else
```

`destination` is the bot user ID of the OA that received the message — this is how one endpoint serves every rep's OA
in the org. The signature is HMAC-SHA256 over the **raw body** with that OA's channel secret, compared in constant
time by `LineSignatureVerifier`.

Three things this class deliberately does **not** do:

- **No business DML.** It publishes `LINE_Webhook_Event__e` and returns. Unauthenticated traffic can never write a
  business record.
- **No callouts.** Nothing external can make us wait.
- **No logging at all.** A log write is a record write; junk traffic must not be able to fill the subscriber's storage.

The guest user holds exactly one permission set, `LINE_Webhook_Guest`: this Apex class and Create on the platform
event. It has no access to the OA configuration or to the secret — the class reads those in system mode, after the
signature has authenticated the request.

### 3.2 Why a platform event in the middle

`LINE_Webhook_Event__e` holds the OA's Id, the LINE event Id and the raw event JSON. It buys three things:

- **LINE gets its 200 immediately.** LINE expects a fast response and retries otherwise.
- **The work runs as Automated Process**, not as the guest user, so it can create records the guest could never touch.
- **A different transaction**, so the processing may query, write and enqueue callouts freely.

### 3.3 Processing — `LineInboundService`

Runs from `LineWebhookEventTrigger` → `LineWebhookEventTriggerHandler`. Platform event triggers get up to 2,000
events at once, so this class uses a **fixed number of queries and DML statements** no matter how many events arrive:

1. **Parse and filter.** Keep `message`, `follow` and `unfollow`, 1:1 only, skip `standby` mode.
2. **Resolve owners** (`OwnerResolver`): the OA's assigned rep while the OA is active, otherwise the fallback owner
   from settings, and never Automated Process.
3. **Upsert conversations** by `Unique_Key__c` (`<channelId>:<lineUserId>`) — one conversation per customer *per OA*.
4. **Upsert messages** by `Webhook_Event_Id__c`, which makes LINE's redeliveries harmless: a repeat is a no-op and
   does not re-bump the unread count.
5. **Notify** the owner through the `LINE_New_Message` custom notification, capped at 100 per batch.
6. **Enqueue one `LineCalloutQueueable`** for the follow-up work that needs a callout.

Everything here runs in system mode on purpose: Automated Process has no sharing context, and a message must be
stored whatever the subscriber's configuration says.

### 3.4 The follow-up — `LineCalloutQueueable`

Callouts cannot happen in a trigger, so they happen here, one queueable per transaction carrying a work list, which
chains itself if the list is long. Each execution does **all callouts first, then all DML** (hard rule 6).

Two work types today:

- `PROFILE` — `GET /v2/bot/profile/{userId}` gives the customer's display name and picture, which become the
  conversation's name. Until this returns, the conversation is named after the opaque `U4a6a…` user ID.
- `WEBHOOK_TEST` — used at registration to record whether LINE could reach us.

### 3.5 Contacts — `LineLinkService`

After the profile callout, a conversation with no Contact gets one (DEC-27):

- A Contact **already holding that LINE user ID** always wins. One person who chats with two reps' OAs has two
  conversations and **one** Contact.
- Otherwise, while `Auto_Create_Contact__c` is on (the default), a Contact is created: `LastName` = the LINE display
  name, `LINE_User_Id__c` and the originating OA set, owner = the rep who owns the conversation.

It runs *after* the profile callout precisely so the Contact is named "สมชาย" and not `U4a6a0e38…`.

The insert is `Database.insert(…, false, SYSTEM_MODE)` and failures are logged, never thrown. If the subscriber has a
validation rule we know nothing about — Account required, a custom field required — the Contact is refused, the
conversation stays unlinked, and **the message is still stored**. That asymmetry is hard rule 7, and it is the single
most important rule for surviving in an unknown org: *nothing about Contacts or Events may cost us a message.*

---

## 4. Outbound: a rep replies

### 4.1 `lineChat` on the Contact page

An LWC showing the conversation as bubbles, with the OA's tabs when a Contact has more than one, an unfollowed
banner, failed-send badges, and older messages loaded either by a button or by scrolling to the top (the scroll
position is preserved around the insert, so reading doesn't jump).

It **polls** rather than streams: every few seconds, `getMessagesSince`, and **only while
`document.visibilityState === 'visible'`**, so a background tab costs nothing. The interval comes from settings.
Timers are cleared in `disconnectedCallback`.

### 4.2 `LineChatController` — the user-mode gate

Everything a rep can reach goes through this class, and it is the only place where user permissions are enforced:
`with sharing`, every query `WITH USER_MODE`. If the rep cannot see the conversation, the query returns nothing —
there is no separate access check to forget.

Reads use **keyset pagination** on (`Sent_At__c`, `Id`), never `OFFSET` (D12), so the millionth message pages as fast
as the first.

### 4.3 `LineOutboundService` — callout, then DML

`POST /v2/bot/message/push` first, the record afterwards. In that order for a reason: if the transaction dies
half-way, the worst case is a message LINE delivered that we failed to store — recoverable and visible. The reverse
order would show the rep a "Sent" bubble for a message that never left, which is a lie the rep cannot detect.

Every attempt is stored either way. A failure gets `Status__c = 'Failed'` and a readable `Error__c` (LINE's own
wording is passed through where it helps — "monthly limit reached" is the rep's problem to escalate, not a mystery).
Pushes carry `X-Line-Retry-Key`, and LINE's `409` ("already accepted") counts as success.

This class is `without sharing`, because `LineChatController` has already checked the rep in user mode and the rep
usually may not edit the conversation record or create message rows — message fields are read-only to reps by design.
The class carries a file-wide Code Analyzer suppression saying exactly that.

---

## 5. Administration

`lineAdmin` on the **LINE Admin** tab, behind `LineAdminController`, whose every method starts with
`FeatureManagement.checkPermission('LINE_Admin')` — the custom permission, not a profile name, because we cannot know
the subscriber's profiles.

Three jobs today:

- **Settings** — the Site base URL (from which the webhook URL is computed and displayed), the fallback owner, poll
  interval, retention, invite expiry, auto-create-Contact, daily sync.
- **Register an OA** — Channel ID + secret + rep. `LineOAConfigAdminService` then issues a token (which proves the
  credentials), reads `/v2/bot/info` for the bot user ID, **sets the webhook URL at LINE**, runs LINE's webhook test,
  and only then writes the OA configuration and stores the secret. Callouts first, DML last, again.

- **Nightly jobs** — shows whether the nightly job is scheduled and how the last daily sync went, with *Schedule*,
  *Unschedule* and *Sync today now* buttons (section 5.1).

Registering is what points a real OA at a particular org — which is why moving from a scratch org to the QA org is
just a matter of registering the OA there.

This page exists earlier than planned (DEC-25). It had to: in a subscriber org only `global` members are callable
from anonymous Apex, and the only `global` class is the webhook, so without a UI a subscriber admin could not
register an OA at all. The nightly-jobs buttons came early for the same reason (DEC-29): a subscriber cannot schedule a
package class from Setup either.

### 5.1 Daily Activity History — `LineDailyEventSyncBatch`

LINE Message is the record of every bubble; Activity History is where Salesforce users actually look. So once a night
(01:00, started by `LineScheduler`) a batch turns **each conversation's day into one Event**:

```
Subject      LINE Conversation – Somchai – May Sales OA
Who          Somchai (Contact)          What   Acme (the Contact's Account)
LINE Conv.   LC-000001                  Owner  May (the rep)        Show as  Free
Start / End  10:01 / 10:08 (first and last message of the day)
Description  10:01 Customer: Could you send the revised quotation?
             10:03 May: Sure, I will send it today.
             10:08 Customer: [Sticker]
```

The shape follows section 2.8 of the business's design document (DEC-28). The details that make it safe to run
unattended for years (DEC-30):

- **A day** is midnight to midnight in the org's default time zone; transcript times are shown in the rep's. The org's
  time zone must therefore be the business's (install step C5, DEC-32); the LINE Admin page warns when it differs from
  the admin's.
- **Idempotent:** each Event carries `LINE_Sync_Key__c` = `<conversation Id>:<date>`. A rerun finds it and **rebuilds** it
  from the stored messages, so a rerun never duplicates and also picks up a message that arrived late.
- **Skips** conversations with no Contact, and conversations that had no messages that day.
- **`ShowAs = Free`**, so a busy chat day never blocks the rep's calendar.
- **Partial success:** if a subscriber's validation rule rejects one Event, that one is logged and the rest are created.
- **`without sharing`**, because the job runs as whichever admin scheduled it and must see every conversation whatever
  that admin's sharing is. Nothing it reads is shown to anyone.

*Sync today now* runs the same batch for **today so far**; that night's run rebuilds the same Event with the whole day.

---

## 6. Data model

| Object | Holds | Key |
|---|---|---|
| `LINE_OA_Configuration__c` | One rep's OA: channel ID, bot user ID, basic ID, assigned rep, active flag, webhook status | `Channel_Id__c` |
| `LINE_Conversation__c` | One customer ↔ one OA. Owner = the rep. Unread count, last message preview, status, Contact | `Unique_Key__c` = `<channelId>:<lineUserId>` |
| `LINE_Message__c` | One message: direction, type, text, sender, sent-at, status, error, file/sticker/location details | `Webhook_Event_Id__c` |
| `LINE_Webhook_Event__e` | Transport only: OA Id, event Id, raw JSON | — |
| `LINE_OA_Credential__c` | **Protected** custom setting: the channel secret, keyed by channel ID | Name = channel ID |
| `LINE_Settings__c` | Org-level settings | — |
| `Contact` | Four packaged fields: `LINE_User_Id__c`, `LINE_OA_Configuration__c`, `LINE_Invite_Code__c`, `LINE_Invite_Expires_At__c` | |
| `Event` | Two packaged fields: `LINE_Conversation__c` (lookup) and `LINE_Sync_Key__c` | `LINE_Sync_Key__c` = `<conversationId>:<date>` |

The schema is **fixed** (`03`). Changing it needs a decision in `DECISIONS.md`, because a packaged field is permanent.

Everything upserts on an external ID rather than querying-then-inserting: it is bulk-safe and idempotent, which is
what makes LINE's redeliveries a non-event.

---

## 7. Security

The package is built to AppExchange security-review standards (`09` §7), which mostly means a handful of rules
applied without exception.

**Secrets.** Channel secrets live only in `LINE_OA_Credential__c`, a **protected** custom setting, which a subscriber
admin cannot read through Setup, SOQL or the API — verified against a real install. Only `LineCredentialStore`
touches it. A secret must never reach a DTO, an LWC, a log, a `System.debug`, an error message, a test or a doc.
Access tokens are stateless: issued on demand from the ID + secret, cached for the transaction, valid ~15 minutes, and
never stored.

**Sharing.** Every class declares it. User-facing code (`LineChatController`, `LineAdminController`) is
`with sharing` and runs `WITH USER_MODE`. `without sharing` appears only where `02` §2 lists it — the webhook, inbound
processing, the queueable, the credential store, the outbound service, the link service — and each one carries a
comment saying why.

**The guest surface** is one Apex class and Create on one platform event. Nothing else.

**Logging** goes through `LineLogger`: buffered, flushed by the entry point, system-mode insert, masks bearer tokens
and secrets, and **never throws** — a logger that can break the thing it is logging is worse than no logger.

**Code Analyzer** must show no Critical or High findings. The Moderate ones that remain are listed with
justifications in `DECISIONS.md` §3 rather than suppressed silently.

---

## 8. Building for unknown orgs

The habits that this constraint forces, which are otherwise easy to mistake for paranoia:

- **No profile names, no hardcoded IDs, no org-specific URLs** — in code or in tests. Test users are picked by
  *permission* and licence, never by profile name.
- **`LineNamespace`** works the prefix out at runtime from its own class name, so the source never contains it and the
  same code runs in a namespaced scratch org, a subscriber org and a plain dev org.
- **All settings through `LineSettings`**, with defaults in code, so a missing settings record is normal rather than
  an error.
- **All text through Custom Labels** (54 of them, with Thai translations), because subscribers translate.
- **Record pages are not auto-activated.** Subscribers add the components themselves.
- **Contact and Event DML is partial-success and logged**, never fatal.

---

## 9. Testing

187 Apex tests and 25 Jest tests, org-wide coverage 93%.

- Callouts are mocked with `LineHttpMock`; test data comes from `LineTestFactory`; no `SeeAllData`.
- Webhook tests build a genuinely **signed** `RestContext.request` and then `Test.getEventBus().deliver()`, so the
  whole inbound path is exercised, signature check included.
- `System.runAs` covers visibility: a test asserts that Rep B cannot see Rep A's conversations.
- At least one "subscriber rejected the DML" test per business object, asserting the message survives.

Two traps worth knowing before you write a test, both learned the hard way and recorded in `DECISIONS.md`:

- **Every test method starts with `LineTestFactory.ensurePackageAccess()`**, and every query or DML on a package
  object uses `WITH SYSTEM_MODE` / `insert as system`. The package build org's test user has no package permission
  sets, so a query that passes in every scratch org fails in the one place that matters (DEC-24). Assigning a
  permission set mid-transaction does not help: permissions are computed when the transaction starts.
- **A callout after DML** throws "uncommitted work pending". It bites `registerOA` in scripts and tests, not in the
  UI, where saving settings and registering are separate Apex calls (DEC-26).

---

## 10. What is built, and what is not

**Working end to end:** inbound webhook → storage → notification, the chat panel, outbound text, OA registration and
settings from the admin page, automatic Contact creation. **Built and tested, awaiting its first package version:** the
daily Activity History sync and its scheduling buttons (M9).

**Not built yet:** QR/link invites and the rep inbox (the rest of M6), images and files (M7), the remaining admin
actions — rotate secret, reassign, deactivate, quota display, error log (M8), the retention and reassignment batches
(M8, M10). `06-implementation-plan.md` is the running order;
`HANDOFF.md` is the current state.

**Known product limits**, all in `08`: replies sent from the LINE OA Manager app never reach Salesforce; polling is
~5 s, not instant; inbound files are capped near 10 MB by Apex heap; LINE bots cannot send file attachments, so
documents go as expiring links; 1:1 chats only; Contact record pages only.

---

## 11. Where to look next

| Question | File |
|---|---|
| What is it supposed to do? | `01-requirements.md` |
| Why is it built this way? | `02-architecture.md` (D1–D12), `DECISIONS.md` |
| What are the fields called? | `03-data-model.md` |
| What does LINE actually return? | `04-line-api-reference.md` |
| How do I set up an org? | `05-setup-runbook.md`, `scripts/setup-scratch.sh` |
| What's next? | `06-implementation-plan.md`, `HANDOFF.md` |
| How do I test it? | `07-testing.md` |
| What can't it do? | `08-limitations-and-open-questions.md` |
| How does it ship? | `09-packaging.md` |
| What are the working rules? | `../CLAUDE.md` |
