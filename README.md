# Spot Check — Backend

The single schema source of truth for Spot Check's Supabase backend
(Postgres + PostGIS, Auth, Storage, Realtime), shared across clients —
today `spot-check-iOS`, with Android to follow. Extracted out of
`spot-check-iOS/supabase/` (see `docs/briefs/01-environment-foundation.md`)
so a second client repo never needs to fork the migration history.

Client repos reference this repo as the schema source but don't need the
SQL at build time — only at CI promotion time (see "Migration promotion"
below).

## Local development

Prereqs: Docker running, Supabase CLI (`brew install supabase/tap/supabase`).

```sh
supabase start      # boots the local stack (Postgres, Auth, Storage, Realtime, Studio)
supabase db reset   # (re)applies every migration in supabase/migrations/ + supabase/seed.sql
```

Studio UI: http://127.0.0.1:54323. API: http://127.0.0.1:54321.

## Migration promotion

1. **Local** — `supabase db reset` applies all migrations + seed.
2. **Local → Test/QA** — automatic on merge to `main`
   (`deploy-qa.yml`): `supabase link --project-ref <ref> && supabase db push`,
   no approval gate (Test/QA is disposable).
3. **Test/QA → Staging** — manual `workflow_dispatch`
   (`promote-staging.yml`), stubbed for now ahead of the RLS-verification
   gate (a later brief); once the `staging` GitHub Environment has
   required reviewers, triggering that dispatch *is* the human-approval
   gate.
4. **Staging → Production** — same `db push` mechanics, under a
   `production` GitHub Environment requiring human approval — never run
   ad hoc from a laptop. Not yet wired (later brief).
5. **Rollback** — migrations are forward-only; fix forward with a new
   corrective migration, never edit an applied file.

## Environments

| | Local Dev | Test/QA | Staging | Production |
|---|---|---|---|---|
| Supabase project | `supabase start` Docker stack | `spot-check-test` | `spot-check-staging` | `spot-check-production` |
| Promotion gate | `supabase db reset` clean, open a PR | Auto-push on merge to `main`, no gate | RLS-verification suite + required-reviewer approval | Same mechanics, human approval required |

Full rationale: `docs/briefs/01-environment-foundation.md`.
