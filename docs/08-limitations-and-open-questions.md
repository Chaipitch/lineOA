# 08 — Limitations, Risks, Open Questions

## Product limitations (communicated to the business)

| # | Limitation | Mitigation |
|---|---|---|
| L1 | Replies sent from LINE OA Manager (app/web) never reach Salesforce. Evidence and options for the BA: `LINE_API_OA_MANAGER_LIMITATION.md` | Turn Chat off per OA (recommended), or a business rule: reply from Salesforce only |
| L2 | Each OA has its own LINE plan and monthly message allowance; Salesforce replies are push messages and count | The client sizes plans; a clear "monthly limit" error today; `lineAdmin` shows each OA's quota in **M8a**, with stored fields and rep-facing warnings as M8b/M8c |
| L3 | Per-rep OA setup in the LINE consoles is manual (~20–30 min per rep) | The Salesforce side is one form in `lineAdmin` |
| L4 | One OA = one rep; splitting a rep's customers means customers must add the new rep's OA | Reassign the whole OA; generic OA names |
| L5 | Chat refresh is polling (~5 s), not instant | Custom notifications for instant alerts |
| L6 | Inbound files limited to ~10 MB by Apex heap/callout limits | "Too large, view in LINE" |
| L7 | LINE bots can't send file attachments; documents go as expiring links | ContentDistribution with expiry |
| L8 | 1:1 chats only | Groups out of scope |
| L9 | Storage grows with message volume | Retention setting |
| L10 | Contact record pages only (no Person Account page support in MVP) | Backlog |
| L11 | PDPA: chats and files stored in Salesforce | Client provides consent/notice; retention |
| L12 | Sticker pictures come from LINE's sticker CDN, which LINE doesn't document; animated stickers show as still pictures | Falls back to "[Sticker]" if the CDN changes (DEC-32) |

## Technical risks (verify early; results go to DECISIONS.md)

| Risk | Checked in |
|---|---|
| Stateless token issuance works with Channel ID + secret | ✅ Verified live (DECISIONS §2) |
| Same LINE user ID across OAs under one Provider (auto-link depends on it) | M6 |
| `line.me/R/oaMessage` pre-fill works for users who haven't added the OA yet (iOS/Android) | M6 |
| Automated Process user can send custom notifications and run callout queueables | ✅ Verified live, also in the installed package (DECISIONS §2) |
| CustomNotificationType is packageable and resolvable in subscriber orgs | ✅ Verified in Beta 1 (DECISIONS §2) |
| LINE accepts Salesforce `ContentDownloadUrl` for images/video | M7 |
| Reply token validity is long enough for PE → queueable latency | M6 |
| Guest user + package licensing interaction (before any LMA licensing) | Before licensing |
| Scratch org features needed for Sites | ✅ M0 (`setup-scratch.sh` creates the Site) |
| ✅ **Resolved (DEC-31):** the Dev Hub is `sf-line-dev` (Enterprise Edition trial, not a PBO) and owns the package; betas can't be installed in it, so the QA org is a separate Developer Edition org, `chaipitch-devhub`. A **PBO is still needed** before an AppExchange listing or LMA licensing, and moving a package to another Dev Hub is hard. Daily limits here: 3 active scratch orgs, 6 package versions. | Before licensing |
| ✅ **Resolved (DEC-25, DEC-29):** anything a subscriber admin must run (register an OA, schedule the nightly job) is a button on the LINE Admin page, because only `global` members are callable in a subscriber org and the only global class is the webhook. Keep this in mind for every new admin action. | Every milestone |
| Apex tests create users (up to ~3 per test: Rep A, Rep B, admin). Orgs with no spare "Salesforce"/"Salesforce Platform" licences (a scratch org has 2 + 3, some already used) fail with `LICENSE_LIMIT_EXCEEDED`. Mitigation: `LineTestFactory` uses either licence, tests use the running admin as the admin, and each test creates at most 2 users. Watch this in the package-version build org. | M3 |
| Platform event triggers get batches of up to 2,000 events by default, and the batch size can't be set without a subscriber-side `PlatformEventSubscriberConfig` (not packageable). `LineInboundService` uses a fixed number of queries and DML statements per batch, and notifications are capped at 100 per batch; confirm CPU/heap headroom with a 2,000-event test in the M11 load check. | M11 |
| ✅ **Resolved:** the first beta was built after M5 with real metadata, so an empty beta was never needed. | – |
| **Stale secrets (found 2026-10-03).** LINE sends no event when a channel is deleted, nothing in the package calls `LineCredentialStore.remove()`, and subscriber admins can't reach the protected setting, so a secret stays until the package is uninstalled. A deleted channel's secret is dead (LINE issues no token for it), but a deactivated-yet-live OA keeps a working secret we no longer need. Storage is negligible (<1 KB each). Proposed for M8: a *Remove OA* action that deletes the secret and keeps the history; a nightly credentials check that flags OAs LINE rejects; delete the secret whenever an OA record is deleted. No automatic deletion. **Agreed 2026-10-03; planned in 06 M8.** | M8 |

## Open questions — business (via BA)

1. Can reps keep replying from the LINE OA Manager app, or Salesforce only? (L1)
2. When a rep leaves: does the whole OA move to one new rep (recommended), or are customers split?
3. Should Contact Owner follow the OA's rep on reassignment? (setting exists; what's the default?)
4. Default message retention period?
5. Do managers need to reply on behalf of a rep, or only read?
6. Invite message wording in Thai/English (shown in the customer's LINE).
7. Do target clients use Person Accounts? (affects post-MVP priority)
8. Should the package **enforce** one active OA per rep, or is that an operational rule only? (Raised by the TA review
   document, 2.2. The package neither enforces nor depends on it.)
9. Are Opportunity links wanted in a later phase? A daily Event's `WhatId` holds the Contact's Account (DEC-28), and
   nothing in the schema links a conversation to an Opportunity. (Raised by the TA review document, 3.3.)

## Open questions — ours

1. ~~Package name and namespace~~ **Answered:** LINE Connect, `tsthlineoa` (DEC-23).
2. ~~Dev Hub~~ **Answered for now:** `sf-line-dev` (DEC-31). Joining the Partner Program for a PBO is still needed before listing or licensing.
3. Licensing model later (free, per-org or per-user). Affects the guest-user design check above.
4. ~~Can `archive/` be deleted?~~ **Answered 2026-09-22:** keep it.
5. ~~Permission-set differences and `Public_Url__c` type~~ **Approved 2026-09-22** (DEC-13, DEC-14).
6. ~~Should a new LINE user get a Contact automatically?~~ **Answered 2026-09-24**: yes, on the first message, only
   when the LINE user ID is new, on by default (DEC-27).
7. **Quota (M8): display only, or also block sending?** The plan shows quota: live fetch (M8a), optionally stored on
   `LINE_OA_Configuration__c` for reports and alerts (M8b, permanent packaged fields) and a warning to reps (M8c). The
   BA's TA review document proposes **blocking** pushes at a threshold instead (`BA_TA_REVIEW_CORRECTIONS.md` section B).
   **Needed before the TA review on 7 Oct 2026.**
8. ~~Field history on `LINE_OA_Configuration__c`?~~ **Approved 2026-09-22** (DEC-22).
