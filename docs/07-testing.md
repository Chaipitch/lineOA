# 07 — Testing

Three layers: **Apex/Jest in scratch orgs** (every milestone), **real LINE end-to-end in the QA org** (every beta), and **install/upgrade tests** (every beta and release).

## 1. Apex unit tests

Rules:
- No `SeeAllData=true`. No real secrets or IDs; fake values only.
- No profile names; they're localized in Thai orgs. `LineTestFactory.createUser()` picks a profile by permissions
  (e.g. `SELECT Id FROM Profile WHERE UserType = 'Standard' AND PermissionsModifyAllData = false LIMIT 1`) and assigns package permission sets.
- Tests must not depend on subscriber customizations. Create the minimum valid Contact (`LastName` only) and expect partial-success paths.
- Every class ≥ 75%, overall ≥ 85%. Test behaviour: assert records, statuses and callouts made, not just coverage.

### Test data
- Rep A and Rep B (`LINE_Chat_User`), Admin (`LINE_Admin`).
- 2 `LINE_OA_Configuration__c`: Channel ID `1000000001`/`1000000002`, bot user ID `Ubot_a`/`Ubot_b`. Secrets `testsecret_a`/`testsecret_b` are set via `LineCredentialStore.putSecret`.
- `LineTestFactory.webhookBody(destination, events)`, `LineTestFactory.textEvent(userId, text, eventId)`, `followEvent`, `fileEvent`…
- `LineTestFactory.sign(body, secret)` → `EncodingUtil.base64Encode(Crypto.generateMac('hmacSHA256', Blob.valueOf(body), Blob.valueOf(secret)))`.

### Calling the webhook
```apex
RestRequest req = new RestRequest();
req.requestURI = '/services/apexrest/line/webhook';
req.httpMethod = 'POST';
req.requestBody = Blob.valueOf(body);
req.addHeader('X-Line-Signature', LineTestFactory.sign(body, 'testsecret_a'));
RestContext.request = req;
RestContext.response = new RestResponse();
LineWebhookResource.handlePost();
Test.getEventBus().deliver();   // runs the PE trigger
```

### HTTP mock
`LineHttpMock` routes by method + path (`/oauth2/v3/token`, `/v2/bot/info`, `/v2/bot/profile/`, `/v2/bot/message/push`,
`/v2/bot/message/reply`, `/content`, `/webhook/endpoint`, `/webhook/test`, `/quota`). Configurable status/body per route; records the requests made.

### Cases (minimum)

| Area | Case |
|---|---|
| Signature | valid → 200 + PE; wrong → 401, nothing published; missing header → 401; lowercase header name → accepted |
| Routing | destination A → owner Rep A; unknown destination → 401, same as a bad signature (DEC-38) |
| Events | empty events → 200; many events in one body; 200 PEs in one trigger batch (bulk); group source ignored |
| Idempotency | same `webhookEventId` twice → one message |
| Follow/unfollow | follow creates a conversation + a profile job; unfollow → Unfollowed; re-follow → Following |
| Inactive OA | owner = fallback owner; no notification when the owner is a queue |
| Send authorization (DEC-37) | assigned rep sends; a user who can see the conversation but isn't the rep gets `LINE_Chat_Not_Assigned_Rep`, no callout, panel read-only; inactive OA → fallback owner and fallback-queue member send, the former rep can't |
| Rotate secret (DEC-45) | new secret checked with LINE (not a cached token) then stored, status Valid; a rejected secret leaves the old one; blank secret, removed OA and unknown OA refused before any callout; admins only |
| Files (DEC-43) | image → File on conversation and Contact (incl. a Contact created in the same run); file over the limit never fetched; external media stays a placeholder; 404 → Download Failed; over limit after download → Too Large; video still transcoding → delayed retry; memory budget chains the rest; small JPEG sent as a LINE image, PDF as an expiring link; only a File on the conversation can be sent |
| Default Account (DEC-36) | created Contact gets the default Account; deleted default → logged, Contact created without one; an existing Contact is never moved |
| Linking — manual | sets Contact__c + Contact.LINE_User_Id__c + primary OA if blank; conflicts refused; no Edit on Contact → refused; refusal names the holder only if the rep can see it |
| Linking — placeholder (DEC-34) | an auto-created holder is replaced: ID moves, the customer's other OA conversations and daily LINE Events move, the empty placeholder is deleted; a placeholder with other records (e.g. a Task) is kept |
| Chat panel linking and stickers (DEC-44) | link from the panel opens the chosen Contact; unlink offered and allowed only to admins; only sendable stickers go out (others refused before any callout); only the assigned rep sends stickers |
| Linking — auto | second OA conversation auto-links by LINE user ID |
| Linking — auto-create (DEC-27) | first message from an unknown LINE user → Contact created (LastName = LINE display name, `LINE_User_Id__c`, primary OA, owner = rep) and linked; an existing Contact with that ID → linked, no new Contact; same person on two OAs → one Contact; follow without a message → no Contact; setting off → none; display name over 80 chars → cut; Contact insert rejected → logged, conversation unlinked, message still stored |
| Notifications | the rep who owns the conversation is notified; a customer's first message (profile not fetched yet) says "a new LINE customer", not the raw LINE user ID |
| Linking — invite (DEC-42) | valid code links + clears code + replies (no auto-created duplicate, no push); expired/unknown code → no link, refused reply; code in the middle of the text still matches; lower case or 9 characters don't match; a redelivery replies once; an expired reply token is logged, never pushed; `createInvite` needs an active OA of your own |
| Subscriber automation | a Contact validation rule that blocks updates → message still stored, link failure logged |
| Outbound | text/image/document success → Sent + Sender; 429 monthly limit → Failed + readable error; 409 → Sent; no access to the conversation → exception |
| Files | download → ContentVersion linked to conversation (+ Contact); over the size limit → Too Large, no callout; download 5xx → Download Failed + retry path |
| Visibility | `System.runAs(RepB)`: can't read Rep A's conversations/messages through the controller or SOQL |
| Reassignment | batch moves owners; optional Contact Owner update; Rep B now reads the history |
| Admin | non-admin calling any `LineAdminController` method → refused; settings round trip (auto-create, daily sync, blank numbers → defaults); register fills bot fields, sets the webhook, stores the secret; bad credentials → nothing saved; nightly jobs: schedule, run now, unschedule, time zones shown; remove OA (secret deleted, OA inactive and *Removed*, history kept; unknown OA → message); rotate secret (M8) |
| Credentials (DEC-33) | registration → *Valid*; nightly check: accepted → *Valid*, rejected by LINE → *Rejected* + logged, LINE unreachable → unchanged, no stored secret → *Rejected*; *Removed* OAs not checked; check runs even with daily sync off; deleting OAs deletes their secrets (bulk); an OA with conversations can't be deleted; re-registering a removed OA restores it |
| Secret handling | no controller DTO contains the secret (serialize and assert) |
| Daily sync | 3 messages in one conversation yesterday → one Event (Who = Contact, What = Account, `LINE_Conversation__c`, owner, subject, times, transcript, `ShowAs` Free); rerun → still one, **rebuilt** with a late message; unlinked conversation → none; no messages that day → none; sync off → none; queue owner → running user; Event rejected → logged, other Events still created; transcript truncated at 32,000; start/end rounded out to whole minutes; 100 conversations in one run; day boundaries across DST; scheduler: schedule twice = one job, unschedule, run now = today |
| Retention | messages older than N months deleted with files; 0 = none deleted |

## 2. LWC Jest
`lineChat`, `lineInvite`, `lineAdmin`: render, empty state, send/success/error toast, polling starts/stops on visibility, paging.
`lineChat` stickers: picture shown from `stickerUrl` without a bubble; picture fails to load → `[Sticker]`; no URL → `[Sticker]`.
Apex: `LineApiClient.stickerImageUrl` accepts digits only (path, host and letters rejected); a sticker `MessageView` carries the URL.

## 3. End-to-end in the QA org (each beta)

Pre: 2 OAs registered in LINE Admin (OA-A → Rep A, OA-B → Rep B); phones 1 and 2 with LINE (iOS + Android).

1. Rep A opens Contact "Somchai" → Invite via LINE → phone 1 scans the QR → sends the pre-filled message. → Linked, confirmation received, Rep A notified.
2. Phone 1 sends text, a sticker, a photo and a PDF. → All shown in `lineChat` within ~10 s; the sticker as its picture; the files are Salesforce Files.
3. Rep A replies with text, an image and a document. → Phone 1 receives them from OA-A; the document is a working link.
4. Phone 1 adds OA-B and says hi. → Auto-linked to Somchai; only Rep B sees it.
5. Phone 2 adds OA-A without an invite and sends "hello". → A Contact named after phone 2's LINE display name is
   created, owned by Rep A, and the chat shows on it (DEC-27). Rep A's first notification says "a new LINE customer".
   Then turn **auto-create off** in LINE Admin → Settings, and repeat with a third LINE account: → no Contact; the
   Rep A opens the Contact LINE Connect created and links the chat to the real Contact from the chat panel (DEC-44).
6. `curl` with a fake signature → 401, nothing stored.
   ```
   curl -i -X POST https://<site>/services/apexrest/<ns>/line/webhook -H 'Content-Type: application/json' \
     -H 'X-Line-Signature: invalid' -d '{"destination":"Ubot","events":[]}'
   ```
7. LINE console redelivery of an event → no duplicate.
8. Admin reassigns OA-A to Rep B. → Rep B sees the OA-A history; Rep A doesn't.
9. LINE Admin → Nightly jobs → **Sync today now** → one Event per conversation for today on the Contact's Activity timeline, with the right transcript. **Schedule** → the card shows the next run at 01:00.
10. Reply from the LINE OA Manager app → confirm it does **not** appear (documented limitation).

Record the results, timings and screenshots in `docs/QA_RESULTS_<version>.md`.

## 4. Install & upgrade tests

| Test | When |
|---|---|
| Clean install into a fresh org + 05 Part C only → E2E steps 1–3 | Every beta |
| Install with "Admins only" and with "specific profiles" | RC |
| Upgrade: last released → new version with existing data; settings, secrets and schedules preserved | Every release after 1.0 |
| Uninstall leaves no scheduled jobs failing (document the unschedule step in the install guide) | RC |
