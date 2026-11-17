# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.
Upstream's shared repository guidance lives in AGENTS.md (imported below); the sections that follow are fork-only.

@AGENTS.md

## Fork development & deployment workflow (fork-only — keep out of upstream PRs)

This is the `nachtschatt3n/sure` fork of `we-promise/sure`.

### Branch roles

**One branch integrates; many branches contribute.** A branch can be the canonical statement of
what the fork *is*, or a unit of upstream review — never both.

- **`integration`** (renamed from `feat/contracts-trading212` on 2026-08-24) — the *integration &
  deploy branch*. Merges every topic branch plus fork-only meta (this section, dev notes). This is
  what gets built into the deployed image and merged into `main`. **Never PR'd upstream as a
  whole.**
- **Topic branches** — each cut fresh from `upstream/main`, single concern, independently
  PR-able upstream. `feat/contracts-preview` (Contracts feature, kept clean of fork meta),
  `pr2513` (Trading 212, upstream PR #2513), and new work such as `feat/llm-extra-params`.

**Rule: topic branches never merge into each other.** They meet only on `integration`. Nearly
every accidental mega-branch is built one reasonable-looking cross-merge at a time. Historically
`feat/contracts-preview` → `feat/loan-contract-term` → `feat/loan-rate-lock-expiry` →
`feat/contracts-trading212` formed exactly such a stack, and nothing in it ever reached upstream;
`pr2513`, the only genuinely standalone branch, is the only one that did.

Flow for a Contracts change:

1. Edit + commit on `feat/contracts-preview`.
2. `git merge --no-ff feat/contracts-preview` into `integration`.
3. Build the image from `integration` (`publish.yml` → `ghcr.io/nachtschatt3n/sure:sha-<sha>`),
   deploy via GitOps (cberg `helmrelease.yaml` image tag, delegated to the cberg-agent), then
   merge `integration` into `main`.

Fork-only meta (this section, dev notes) lives on `integration` / `main`, **never** on
`feat/contracts-preview`, so the upstream PR stays clean.

### Known fork divergences (expect these to conflict on every upstream sync)

- **Contracts nav entry** — `app/views/layouts/application.html.erb`. Contracts is deliberately a
  **top-level** nav item and is *not* folded into upstream's `plan_nav_item` "Plan" hub (which
  upstream introduced in the 2026-08 sync, absorbing budgets and goals). Upstream actively
  restructures this list, so this line conflicts often. **Resolution: take upstream's
  `plan_nav_item`, then re-add our `preview_gated_nav_item(... contracts_path ...)` after it.**
  Guarded by `test/integration/contracts_nav_test.rb` — that test fails loudly if the entry is
  dropped, which is the only thing standing between a routine sync and a fully intact but
  completely unreachable Contracts feature.

### The Helm chart is upstream's — fork chart edits are INERT

The deployed chart does **not** come from this fork. cberg's HelmRepository
(`kubernetes/flux/meta/repositories/helm/sure.yaml`) points at the **upstream** index
(`we-promise.github.io/sure`); only the *image* comes from `ghcr.io/nachtschatt3n/sure`. Chart and
image are decoupled.

Consequence: **any change under `charts/` in this fork is silently never deployed.** Flux renders
upstream's chart, the image deploys fine, and whatever depended on the fork's template change is
simply absent — no error anywhere. If a future change genuinely needs a chart modification, the
options are an upstream chart PR or repointing the HelmRepository at the fork; editing
`charts/` here and expecting it to apply is not one of them.

As of the 2026-08-24 sync the fork has **zero** divergence under `charts/` (verified: no commit in
`upstream/main..integration` touches it), so this is a trap to avoid, not a current problem. Note
also that the fork's `charts/sure/Chart.yaml` version (0.7.4-alpha.9 after the sync) is meaningless
for deployment — the cberg helmrelease pins the upstream chart independently, at 0.7.3.

### Retired fork patches (do not reintroduce)

- **Insights chat watchdog** (`app/javascript/controllers/chat_controller.js`). The fork used to
  hardcode `responseTimeout: 300000`. Upstream implemented this properly — the value is now
  server-driven via `Chat.response_timeout_ms`, with precedence
  `ENV["AI_RESPONSE_TIMEOUT"] > Setting.ai_response_timeout > default`. The fork patch was deleted
  in the 2026-08-24 sync. **The behaviour now depends on `AI_RESPONSE_TIMEOUT=300` being set in the
  cberg `helmrelease.yaml`** — without it the timeout silently falls back to 90s and the
  "assistant did not reply" bug returns on the slow local model.

## Deploy log

Running record of what shipped in each deployed image, so future sessions don't have to
reconstruct it from git log. Add an entry here whenever `helmrelease.yaml`'s image tag is bumped.

| Date | Image tag | What shipped | Notes |
|---|---|---|---|
| 2026-08-24 | `sha-8588d365c4723c12c4b39e807499f67983a8c063` | Added `contract_term` field to `Loan` (free-text display of the contract's literal stated term, separate from `term_months`) | |
| 2026-08-24 | `sha-b1d513ed277c61028bdb7c8ca48b939ce3e5edca` | Added `rate_lock_expires_on` field to `Loan` (Zinsbindung date + `rate_lock_expiring_soon?` warning) | **Never actually deployed correctly** — `publish.yml`'s `workflow_dispatch` `ref` input defaulted to `'main'`, so this tag's image was silently built from stale `main`, missing this migration (and `contract_term`'s too). Caught via live-pod filesystem inspection before real impact; rolled back to the prior tag. See fix below. |
| 2026-08-24 | `sha-ff195b0315335006b8c890e98654fb6bdc18699c` | Same `rate_lock_expires_on` field, correctly built this time, plus the `publish.yml` fix itself (`ref` input default changed from `'main'` to `''` so unset dispatches fall through to `github.ref`) | Verified via a pre-deploy throwaway debug pod exec, confirming both migrations and their app code were actually present in the image *before* touching the live HelmRelease — do this for every future deploy, don't trust a matching tag name or green CI alone. |
| 2026-11-17 | `sha-f6c524c1d935ed54de9962286b914904a525265b` | Full upstream sync (upstream main 27332f0a9, 989 commits): keeps Contracts, loan fields and the AI-enrichment fixes; upstream's Wise rework replaces the fork's Wise paging fix; Wise enabled | 89 migrations (407 → 496), then `security:backfill_encryption[100,false]`. Rehearsed on copies of production first (parity script + screenshots in `~/code/sure-backups/`). Rollback needs the DB restore from `~/code/sure-backups/2026-11-17-deploy/sure.dump`. After deploy: 49 pending transfers reset by upstream migration were re-confirmed (`Transfer#confirm!` set 6 Trading 212 inflows to `funds_movement`; restored to `investment_contribution`, and entries touched so report caches refresh). Upstream's two default rules (Category classifier, Merchant matcher) switched off. |

**Standing practice since the incident above**: always pass `-f ref=<branch>` explicitly on every
`publish.yml` dispatch even though the default is now fixed, and verify a freshly-built image's
actual file contents (via a throwaway debug pod/job) before bumping the live `helmrelease.yaml`
tag.

