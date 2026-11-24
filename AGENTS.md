# spot-check-backend

This repo holds the Supabase schema (`supabase/migrations/`,
`supabase/seed.sql`, `supabase/config.toml`), the Edge Functions in
`supabase/functions/`, and the CI that promotes both across environments.
No *client* application code lives here.

- `supabase/functions/` is Deno, deployed by the same workflows that push
  migrations, and is the only place a Stripe secret key is ever used. The
  rule it exists to enforce: money and identity state have a SELECT policy
  and no write policy anywhere in the schema, so `stripe-webhook` running
  as service role is the single path by which either changes.
- Function secrets are set by hand (`supabase secrets set`), never by CI —
  the deploy token's Edge Function Secrets scope is deliberately None.
- Type-check functions before opening a PR. There is no local Deno on the
  dev machine; use the container:

      docker run --rm -v "$PWD/supabase/functions":/fn -w /fn \
        --entrypoint deno denoland/deno:latest check */index.ts

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
