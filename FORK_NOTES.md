# Fork notes

Fork-local findings that do not belong in an upstream PR. Lives on the deploy
branch (`integration`) and `main` only — never on `feat/contracts-preview`.

---

## AI merchant detection only ever sees FamilyMerchants

*Recorded 2026-09-05, while investigating the 02:22Z auto-detection run.*

`Family::AutoMerchantDetector#user_merchants_input` builds the "known merchants"
list the model is shown:

```ruby
def user_merchants_input
  family.merchants.map { |m| { id: m.id, name: m.name } }
end
```

`Family` declares `has_many :merchants, class_name: "FamilyMerchant"`, so that
list is **FamilyMerchants only**. The `ProviderMerchant` rows with
`source: "ai"` — the ones this very feature created — are never offered back to
the model.

On this install that is 431 FamilyMerchants shown, against 385 AI-created
ProviderMerchants withheld.

**Consequence:** the model cannot reuse a name it coined on an earlier run. Ask
it twice about the same vendor whose descriptor varies slightly and it invents
a second spelling, so `find_or_create_ai_merchant` (which matches on exact name,
or on `website_url` when one exists — and this model rarely returns URLs) misses
the existing row and creates a near-duplicate. The duplicates accumulate quietly;
nothing in the UI flags two merchants that differ by a legal-form suffix.

Note the same asymmetry in the baseline numbers that confused an earlier count:
the 47 "AI merchants" some queries report are `FamilyMerchant` rows with
`source IS NULL`, which is a different population from the 385 `ProviderMerchant`
rows with `source = 'ai'`. Two populations, easy to conflate.

**Not fixed, and deliberately not part of the upstream PR chain** — widening the
list changes prompt size and dedup behaviour together, and wants its own
before/after measurement. Worth doing; do it as its own change.

Related upstream-bound work (both branched off `upstream/main`, unpushed as of
this note):

- `fix/auto-merchant-detector-local-business-nulls` — prompt fix, batch-budget
  accounting, auto-mode comment
- `fix/auto-merchant-detector-attempt-reasons` — attempt-marker reason split and
  the split TTL, stacked on the two earlier fork fixes
