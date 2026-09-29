# LINE Connect

A **managed 2GP Salesforce package** that connects LINE Official Accounts to Salesforce. Each sales rep has their own
LINE OA; their customers chat with it from the LINE app, and the rep reads and replies from the Contact page in
Salesforce. Conversations, a daily Activity History summary and Contacts for new LINE customers are created automatically.

- Namespace `tsthlineoa`, package **LINE Connect**, API version 67.0.
- Built to AppExchange security-review standards; installed privately into client orgs first.

## Where to start

| You want to… | Read |
|---|---|
| Understand how it works | [docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md) |
| Know where the build stands | [docs/HANDOFF.md](docs/HANDOFF.md) |
| Read the specification | [docs/README.md](docs/README.md), then `docs/01`–`09` |
| See why something is the way it is | [docs/DECISIONS.md](docs/DECISIONS.md) |
| Work on the code with Claude Code | [CLAUDE.md](CLAUDE.md) (loaded automatically) |

## Layout

```
force-app/     everything that ships in the package (Apex, LWC, objects, labels, permission sets)
unpackaged/    org setup for scratch and QA orgs only (the webhook Site's home page)
scripts/       setup-scratch.sh and anonymous-Apex helpers (seed data, smoke tests)
config/        scratch org definition (also used by the package build)
docs/          specification, decisions, security notes, handoff
archive/       reference retrieve of an early org; not used by the build
```

## Everyday commands

```bash
DEVHUB=sf-line-dev DAYS=30 ./scripts/setup-scratch.sh line-dev   # fresh namespaced scratch org, fully set up
sf project deploy start --target-org line-dev --wait 15
sf apex run test --test-level RunLocalTests --target-org line-dev --code-coverage --result-format human --wait 30
npm run prettier:verify && npm run lint && npm run test:unit
sf package version create --package "LINE Connect" --installation-key-bypass --code-coverage --wait 90 --target-dev-hub sf-line-dev
```

Orgs: Dev Hub `sf-line-dev`, QA org `chaipitch-devhub` (installed package versions only), scratch org `line-dev`.
Secrets never go into this repository: channel secrets are entered on the LINE Admin page of an org and stored in a
protected custom setting.
