# Handoff — state of the build

Last updated: **2026-09-22**, after M5. Read `README.md` first, then this file, then `DECISIONS.md`.
This file says where the work stands, what's open, and which traps already cost time. Keep it current at the end of each milestone.

## 1. Where we are

| Milestone | State |
|---|---|
| M0 Packaging foundation | **Done except the beta install.** Namespace `tsthlineoa` linked, `sf package create` done (package `0HogL0000004bNZSAY`, Dev Hub `sf-line-dev`), scripts and docs in place. Beta 1 build + install into the QA org is the last step. |
| M1 Data model & security metadata | **Done.** Deployed to the scratch org. Six approval items are still open (§4). |
| M2 Core services | **Done.** Logger, settings, credential store, namespace, trigger base, API client, DTOs, test factory and HTTP mock. |
| M3 Registration + inbound | **Code done and proven live with a real LINE OA.** Beta 1 and the QA-org end-to-end run are the remaining part. |
| M4 Outbound text | **Done**, verified live: a reply sent from Salesforce reached a real phone. |
| M5 Chat panel (`lineChat`) | **Done**: 146 Apex + 13 Jest tests pass. Loads older messages both by scrolling to the top and by a button (DEC-21). Visual check on a Contact record page still pending. |
| M6 Linking + inbox | **Next**, after the Beta 1 install and QA run. |

**Order change:** M1–M5 were built before the namespace existed (DECISIONS DEC-08). Since 2026-09-22 the namespace `tsthlineoa`
is set in `sfdx-project.json` and development happens in the **namespaced** org `line-ns`, where all 146 tests pass and the
runtime prefix, webhook URL and CustomNotificationType lookup were confirmed. Only the protected custom setting still behaves
differently in an installed package, which the Beta 1 install checks.

Checks at the end of M5: **146/146 Apex tests** and **10/10 Jest tests** pass, LINE classes **94.2%** coverage
(lowest class 90%), Code Analyzer **0 Critical/High**, prettier and ESLint clean.

The scratch org holds live test data: one registered LINE OA, a conversation with real messages, and a Contact
("Chaipitch") linked to it **by a one-off script**, since linking is M6.

## 2. Orgs and access

| Alias | What it is | Notes |
|---|---|---|
| `line-dev` | Development scratch org, **non-namespaced** | Rebuilt 2026-09-22 with `DAYS=30`, so it **expires 2026-10-22**. Recreate with `DEVHUB=sf-line-dev DAYS=30 ./scripts/setup-scratch.sh`. The LINE OA is **not** registered in it yet (the secret must be re-entered through Setup). |
| `sf-line-dev` | Developer Edition. Spec calls it the **QA org**; it is currently also the only enabled **Dev Hub** | Never `sf project deploy` here: installed package versions only. It also holds ~2,700 unrelated SDO demo components. |
| `line-ns` | **Namespaced** scratch org (`tsthlineoa`), created 2026-09-22, expires 2026-10-22 | Where namespaced development and testing happen from now on. No LINE OA registered in it. |
| namespace org | Developer Edition holding the namespace `tsthlineoa` | Linked to the Dev Hub 2026-09-22. Keep the org alive and its credentials safe: the namespace is permanent. |

The scratch org has a Site (`LineWebhook`) whose URL ends in `/linewebhook`, two test reps (Rep A English, Rep B Thai),
permission sets assigned, and `LINE_Settings__c` seeded. `setup-scratch.sh` does all of that and is safe to re-run.

**A real LINE OA is registered in the current scratch org** and its webhook points there. Look it up with:
`sf data query --target-org line-dev --query "SELECT Name, Channel_Id__c, Basic_Id__c, Webhook_Status__c FROM LINE_OA_Configuration__c"`.
It is on the **free LINE plan: 300 push messages a month**, so don't run bulk send tests against it. Replies to invite
codes (M6) are free. When the scratch org is recreated, re-register the OA, which repoints its webhook:

1. Store the secret in the new org through Setup → Custom Settings → **LINE OA Credential** → Manage → New
   (Name = Channel ID, Channel Secret = the secret). Never put a secret in a file, a script or a CLI command.
2. Run `scripts/apex/register-oa.apex` with the Channel ID filled in (it reads the secret from the setting).
3. `scripts/apex/line-smoke-test.apex` checks credentials, bot info, quota and a push, without touching webhook settings.

## 3. What is proven to work (live, not just in tests)

- Stateless token from Channel ID + secret; bot info; quota; push to a phone (DECISIONS §2).
- LINE → Site guest user → signature check → platform event → Automated Process trigger → conversation and message stored.
- The profile callout and custom notification both run **as Automated Process**, with no subscriber-side config (D3 verified).
- Fake signature → 401, unknown OA → 403, junk → 400, and nothing is stored (acceptance criterion 3).

Namespaced org (2026-09-22): runtime prefix `tsthlineoa`, webhook path `/services/apexrest/tsthlineoa/line/webhook`, and the
CustomNotificationType resolved by DeveloperName + NamespacePrefix. 146/146 tests pass there.

Not proven yet: that the protected custom setting is hidden from subscriber admins, and that everything survives packaging.
Both are Beta 1 checks in the QA org.

## 4. Open items, in the order they block work

1. **Dev Hub is `sf-line-dev`**, which is also the QA org: a known compromise (08). The package is now permanently owned by it.
2. **Scratch org limit is 3 active** on this Dev Hub. Check with `sf data query --target-org sf-line-dev --query "SELECT SignupUsername, ExpirationDate FROM ActiveScratchOrg"` before creating one; ask the user before deleting any.
4. **DEC-13 (needs approval):** three permission-set differences Salesforce forces (error log Edit + View All; platform event Read).
   Already deployed; `03 §6` gets updated once approved.
5. **DEC-14 (needs approval, blocks M7):** `Public_Url__c` is specified as URL(1000), but Salesforce URL and Text fields stop at
   255 characters. Recommendation: Long Text Area(1000) under the same API name. **The field is not created yet.**
6. **Field history on OA configuration?** Would satisfy "admin actions are logged" (01 §5); not in 03 today.
7. **Delete `archive/`?** It holds the retrieve of the QA org that was moved out of `force-app/` (DEC-01).

## 5. Traps already hit (don't rediscover these)

- **Don't name an Apex variable or parameter `json`.** Apex is case-insensitive, so it hides the `JSON` class and the error
  ("Method does not exist … from the type String") points somewhere else.
- **Prettier's Apex parser fails on a method called `on(...)`.** The mock's methods are `stub`, `stubBlob`, `stubCalloutException`.
- **`substringAfterLast('.')` returns an empty string when there is no dot.** It silently broke handler names.
- **Apex `==` on Strings ignores case**, which would accept a signature with flipped letter case. Use the constant-time compare
  in `LineSignatureVerifier`.
- **`getNumDml()` on a `DmlException` you constructed yourself throws an uncatchable `UnexpectedException`.** Match on the message.
- **Event/Task custom fields live on `Activity`**, and their permission-set entry must be `Activity.<field>`. An `Event.<field>`
  entry deploys and is then silently dropped (DEC-10).
- **Scratch orgs have very few licences** (2 Salesforce, 3 Salesforce Platform). `LineTestFactory.createUser` tries each licence
  in turn and wraps user creation in `System.runAs` to avoid mixed-DML errors. Keep tests to at most 2 new users.
- **Running Apex tests makes source tracking report conflicts** on the classes that ran, because the org recompiles them.
  `--ignore-conflicts` is safe here; nobody else edits the scratch org.
- **Graph-engine (sfge) findings attach to the *primary* location**, which for the webhook is the query in
  `LineOAConfigSelector`, not the entry point. Suppression markers must sit there (DEC-18).
- **Thai translations need Translation Workbench**, which `config/project-scratch-def.json` now switches on.
- **Salesforce's docs site refuses automated fetches (403).** Use LINE's OpenAPI specs at `github.com/line/line-openapi`, and
  verify Salesforce behaviour by trying it in a scratch org.

## 6. Conventions worth knowing before editing

- Secrets live only in `LINE_OA_Credential__c`, and only `LineCredentialStore` touches it. Nothing else may carry a secret:
  not a DTO, log, test, script or doc. `LineLogger` also masks anything that looks like a token.
- Callouts before DML in every transaction. The webhook does no DML at all, not even logging.
- All user-facing text comes from Custom Labels, with a Thai translation added at the same time.
- Every packaged API name is permanent once released. Check 03 before creating any field, picklist value or object.
- `global` is allowed only on `LineWebhookResource`.

## 7. Suggested next steps

1. **M4 — outbound text** (`LineOutboundService.sendText`, `LineChatController.sendText`): doesn't need the namespace and can be
   tested live against the registered OA. Watch the 300-message monthly quota.
2. **In parallel:** get the namespace linked, then do M0's leftovers (`sf package create`, empty beta) and M3's Beta 1 in `sf-line-dev`.
3. Before M7, settle DEC-14 so `Public_Url__c` can be created with the right type the first time.

## 8. Starting a new session

```
Read docs/README.md, docs/HANDOFF.md and docs/DECISIONS.md, then continue with M<n> of docs/06-implementation-plan.md.
```

Useful commands:

```bash
DEVHUB=sf-line-dev ./scripts/setup-scratch.sh          # fresh scratch org, fully set up
sf project deploy start --source-dir force-app --target-org line-dev --ignore-conflicts
sf apex run test --test-level RunLocalTests --target-org line-dev --code-coverage --result-format human --wait 30
npm run prettier:verify && npm run lint && npm run test:unit
npm run scan                                            # Code Analyzer, fails on High/Critical
```
