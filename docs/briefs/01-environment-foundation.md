# Brief 01 — Environment Foundation

Source: the full Spot Check Engineering Plan (companion doc). This brief
covers only §1, §3, §4, and §7 of that plan — the first two rungs of the
environment ladder plus the iOS-side plumbing to target any of them.
Everything else below (§2 web/mobile transition, §5 Android, §6 full
CI/CD+Fastlane, the RLS-verification gate, Sentry, `feature_flags`) is
explicitly scoped to later briefs — don't pull it forward.

## Context

`spot-check` is pivoting from a web-only learning project into a real
product shipping native iOS and Android apps. The mobile backend
architecture is already decided: **Supabase** (Postgres+PostGIS, Auth,
Storage, Realtime) is the shared backend-as-a-service for iOS and,
eventually, web. That decision was executed only as far as a
**local-only** Docker Supabase stack inside `spot-check-iOS` — zero
commits, no hosted project, no CI/CD, no Android code anywhere yet.

Mobile apps can't be instantly rolled back the way a Vercel deploy can —
users install binaries, and app store review sits in the way. That raises
the cost of a bad release, which is why this plan adds more gates than
the web app currently has: a disposable Test/QA tier, a human-approved
Staging tier that rehearses the exact release process, and (in a later
brief) feature flags / crash reporting so Production itself can roll out
in stages.

## §1 — Environment inventory

| | Local Dev | Test/QA | Staging | Production |
|---|---|---|---|---|
| Supabase project | `supabase start` Docker stack | `spot-check-test` | `spot-check-staging` (Pro + PITR) | `spot-check-production` (Pro + PITR) |
| Data | migrations + `seed.sql`, reset freely | same seed + edge cases, reset on a schedule — stable, not moving | richer synthetic/anonymized dataset approximating real shape | real data |
| Consumers | iOS Simulator (`127.0.0.1:54321`), Android emulator (`10.0.2.2:54321`) | iOS QA config + TestFlight internal · Android `qa` flavor + Play internal · CI test jobs | iOS Staging config + TestFlight external/beta · Android `staging` flavor + Play closed testing | iOS Release (App Store) · Android `prod` (Play production) · web stays on its own backend until a defined cutover |
| Promotion gate → | `supabase db reset` clean, open a PR | Auto-push on merge to `main`, no gate (disposable) | RLS-verification suite + required-reviewer approval | Same mechanics, human approval required, never ad hoc |

**Real test-case users, before public release** — this is specifically
what Staging is for:
- **iOS → TestFlight External Testing.** Invite by email or a shareable
  link, up to 10,000 testers, no Apple Developer team membership
  required. Each build needs a one-time lightweight Apple "Beta App
  Review" (~24–48h) before it reaches external testers; builds expire
  after 90 days.
- **Android → Play Console Closed Testing.** Tester list or Google Group,
  install straight from the Play Store; one review pass per track.

Both point at the Staging config/flavor and the `spot-check-staging`
project — realistic enough to catch real bugs, isolated from disposable
Test/QA data and from Production.

## §3 — Backend repo extraction (this repo)

Before Android scaffolding begins, `spot-check-iOS/supabase/`
(`config.toml`, `migrations/`, `seed.sql`) gets extracted into this repo,
`spot-check-backend`. Both iOS and Android then reference this one repo
as the schema source — client repos don't need the SQL at build time,
only at CI-promotion time. This avoids a painful migration-history split
once a second client repo exists.

`spot-check-iOS/supabase/` is **not deleted** in this pass — that's a
separate, explicitly-gated follow-up decision, not bundled into Brief 01.

## §4 — iOS build configuration plan

Only `Debug`/`Release` configs existed before this brief, both pointed at
the same `Config/Shared.xcconfig` — switching between local and hosted
Supabase meant hand-commenting lines in one file.

| Config | Secrets file | Points at |
|---|---|---|
| Debug | `Secrets.xcconfig` | local Docker stack (unchanged) |
| QA | `Secrets.QA.xcconfig` | `spot-check-test` |
| Staging | `Secrets.Staging.xcconfig` | `spot-check-staging` |
| Release | `Secrets.Production.xcconfig` | `spot-check-production` |

- Three new shared Xcode schemes (`SpotCheck-QA`, `SpotCheck-Staging`,
  `SpotCheck-Release`), marked `shared: true` so CI sees them in a fresh
  checkout.
- Per-environment bundle ID suffixes (`com.spotcheck.ios.qa`, `.staging`)
  for side-by-side installs — needs new App IDs in the Apple Developer
  portal (not needed for this brief — simulator-only, no signing).
- Per-environment URL scheme (`spotcheck-qa://`, `spotcheck-staging://`,
  prod keeps `spotcheck://`), registered in each environment's Supabase
  Auth redirect allow-list (later, once those hosted projects exist).
- Regenerate via XcodeGen after editing `project.yml` — never hand-edit
  `project.pbxproj`.

## §7 — Database migration promotion workflow

Source of truth: this repo's `supabase/migrations/`.

1. Local: `supabase db reset` applies all migrations + seed.
2. Local → Test/QA: automatic on merge to `main` via
   `supabase link --project-ref <test-qa-ref> && supabase db push`. No
   gate.
3. Test/QA → Staging: manual `workflow_dispatch`, gated by an
   RLS-verification step (cross-user privacy, non-participant message
   access, no RLS recursion, signed-URL enforcement) run against Test/QA
   and required to pass first. **Not built in this brief** — the
   `promote-staging.yml` workflow here is a stub ahead of that gate.
4. Staging → Production: same `db push` mechanics, under a `production`
   GitHub Environment requiring human approval — never run ad hoc from a
   laptop.
5. Rollback: migrations are forward-only; fix forward with a new
   corrective migration, never edit an applied file.

## What this brief does not do

- Create any hosted Supabase project (Test/QA or Staging) — billing/
  account action, Alex's to do.
- Add the RLS-verification gate, Sentry, or `feature_flags` — later
  briefs.
- Touch Android, or the web/mobile data-transition bridging — later
  briefs (§5, §2 of the full plan).
- Register Apple Developer App IDs or do any code signing — everything
  here is simulator-only.
