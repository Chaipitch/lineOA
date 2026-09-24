# Messages sent from the LINE OA Manager app are invisible to Salesforce

**Question:** when a sales rep replies to a customer from the LINE Official Account Manager app (or web console),
can LINE Connect show that reply in Salesforce?

**Answer: no.** The LINE Messaging API provides no way to read it. This is a limit of the LINE platform, not of our
package, and no amount of development on our side changes it.

Checked on **23 September 2026** against LINE's own published API definitions. Anyone can repeat the checks below.

---

## 1. What we checked

| Source | What it is |
|---|---|
| [LINE Messaging API reference](https://developers.line.biz/en/reference/messaging-api/) | LINE's official endpoint documentation |
| [github.com/line/line-openapi](https://github.com/line/line-openapi) | LINE's machine-readable API definitions, published and maintained by LINE: `messaging-api.yml` (endpoints) and `webhook.yml` (events LINE sends us) |

Two independent things would have to exist for a rep's app reply to reach Salesforce. **Neither does.**

## 2. There is no endpoint that reads a conversation

Every message-related endpoint in the Messaging API, in full:

| Purpose | Endpoints |
|---|---|
| **Send** a message | `/message/push`, `/message/reply`, `/message/multicast`, `/message/narrowcast`, `/message/broadcast` |
| **Check** a message before sending | `/message/validate/*` |
| **Count** messages delivered | `/message/delivery/reply`, `/delivery/push`, `/delivery/multicast`, `/delivery/broadcast`, `/delivery/pnp` |
| **Monthly quota** | `/message/quota`, `/message/quota/consumption` |
| **Download content the customer sent us** | `/message/{messageId}/content`, `/content/preview`, `/content/transcoding` |
| **Aggregation, read state, typing indicator** | `/message/aggregation/*`, `/message/markAsRead`, `/chat/markAsRead`, `/chat/loading/start` |

There is **no endpoint that returns the messages in a chat**. The delivery endpoints return *numbers only* ("how many
messages were delivered on this date"), never text, and the content endpoints only apply to files a **customer** sent.

## 3. LINE never notifies us about the OA's own messages

LINE pushes events to our webhook. The complete list of event types LINE can send:

```
Message, MessageEdited, Unsend, Follow, Unfollow, Join, Leave, MemberJoined, MemberLeft,
Postback, VideoPlayComplete, Beacon, AccountLink, Membership, Module,
Activated, Deactivated, BotSuspended, BotResumed, PnpDeliveryCompletion
```

A **Message** event always describes a message **sent by a user to the OA**. No event type exists for "the Official
Account sent a message", whoever sent it — the app, the web console or another tool.

## 4. What this means for the business

If a rep replies from the LINE app on their phone:

- the **customer receives it normally**;
- **Salesforce never learns of it**, so the chat panel shows the customer's messages and the replies sent from
  Salesforce, but not that one;
- the **daily Activity History summary** and any reporting will be missing it;
- a colleague or manager looking at the Contact sees an incomplete conversation, which is the real risk: it looks
  complete, but isn't.

## 5. The options

| # | Option | Effect | Cost |
|---|---|---|---|
| **A** | **Turn Chat off** in LINE OA Manager for each OA (Settings → Response settings → Chat off) | Staff **cannot** reply from the app, so Salesforce holds the complete conversation | Reps must work in Salesforce. They lose the convenience of replying from their phone LINE app |
| **B** | Leave Chat on, and make it a **business rule** that reps reply only from Salesforce | Nothing to configure | Relies on discipline; gaps will appear and nobody will know which conversations are incomplete |
| **C** | Leave Chat on and accept partial history | Reps work however they like | Salesforce is no longer a reliable record of customer conversations |

**Our recommendation: A.** It is the only option that guarantees what the project is for — a complete, shared record
of customer conversations in Salesforce. It is a setting per OA, and LINE Connect can show a warning in the admin page
for any OA where Chat is still on (the package already reads that flag when the OA is registered).

If the client insists on reps using the phone app, choose **B** knowingly, and set expectations that Salesforce holds
"most" rather than "all" of each conversation.

## 6. How to verify this independently

1. Open the [Messaging API reference](https://developers.line.biz/en/reference/messaging-api/) and look for any
   endpoint that reads messages. The endpoints are grouped by purpose; all message endpoints are listed in §2 above.
2. Or download LINE's own definitions and list the endpoints:
   ```bash
   curl -s https://raw.githubusercontent.com/line/line-openapi/main/messaging-api.yml | grep -E '^  "/'
   curl -s https://raw.githubusercontent.com/line/line-openapi/main/webhook.yml | grep -E '^    [A-Za-z]+Event:'
   ```
3. Practical test: reply to a customer from the LINE OA Manager app, then check the customer's Contact in Salesforce.
   The reply does not appear, and no error is logged, because Salesforce is never told.

---

*Related: this is limitation **L1** in `docs/08-limitations-and-open-questions.md`, and open question 1 for the BA.
The related limitation **L2** (each OA has its own monthly message allowance, and replies sent from Salesforce count
against it) is unaffected by this choice.*
