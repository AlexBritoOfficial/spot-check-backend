# spot-check-backend

This repo holds nothing but the Supabase schema (`supabase/migrations/`,
`supabase/seed.sql`, `supabase/config.toml`) and the CI that promotes it
across environments. No application code lives here.

- Migrations are forward-only. Never edit a migration that's already been
  applied anywhere (including just locally) — add a new one instead, even
  to fix a typo in the last one.
- This is the schema's single source of truth. `spot-check-iOS` (and any
  future client repo) reference it but don't vendor their own copy of
  `supabase/migrations/`.
- Changes here are validated with `supabase db reset` (applies every
  migration + the seed from scratch) before opening a PR — not just a
  diff review.
- See `docs/briefs/01-environment-foundation.md` for the environment
  ladder (Local → Test/QA → Staging → Production) this repo's CI
  implements, and why it exists.
