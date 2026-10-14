# Rebuilding or restoring the SNA POS database

Read this before you rebuild the database from git, or restore data into a fresh project. Nothing here needs doing while the
live database is healthy, except step 0.

## 0. Do once, now: keep the PIN pepper somewhere safe

The pepper is a hidden value mixed into every staff PIN before it is stored. It exists **only** in the live database
(`app.secrets`, key `pin_pepper`). It is the one secret that cannot be recreated.

1. In the Supabase SQL editor: `select value from app.secrets where key = 'pin_pepper';`
2. Save the value in your password manager (not in git, not in chat, not in an e-mail).

Fingerprint to check a saved copy without showing it (first 12 characters of its SHA-256, taken 14 Oct 2026):
**`498bdd10863f`** — compute with `select left(encode(extensions.digest(value::bytea, 'sha256'), 'hex'), 12) from app.secrets where key = 'pin_pepper';`
The fingerprint cannot be turned back into the pepper.

## 1. What each secret is, and what breaks without it

| Secret | Lives in | If it is lost or different | Can it be recreated? |
|---|---|---|---|
| `pin_pepper` | table `app.secrets` | Staff PIN sign-in and manager PIN approvals stop working. Passwords are not affected (they live in Supabase Auth). | **Only if you saved it.** Otherwise make a new one and reset every staff PIN. |
| `push_secret` | Supabase vault, **and** the app's `PUSH_SECRET` environment variable (must be equal) | Owner phone alerts and scheduled report e-mails silently stop. Billing is not affected. | Yes: make any long random string and set it in both places. |
| `push_url` | Supabase vault | Same as above. | Yes: it is the address of the app's push route, e.g. `https://sna-pos.vercel.app/api/push`. |

## 2. Rebuild from git (new, empty project)

1. Create a Supabase project. Enable the extensions `pg_net`, `pg_cron` and `supabase_vault` from the dashboard.
2. Run `supabase/migrations/001` ... `112` in file-name order (or `supabase/schema/03_live_baseline.sql` alone). Do **not** run 113 on a
   new project unless you want it; it is the grants change described in its header.
3. The migrations create a **new random** `pin_pepper`. A new, empty project has no staff yet, so nothing is lost. Set up
   the first restaurant, owner and staff as normal; their PINs are then made with the new pepper.
4. Create the vault secrets: `select vault.create_secret('<value>', 'push_secret');` and the same for `push_url`.
5. Set the app's environment variables (Vercel), listed below.
6. Prove the structure: `supabase/verify/verify_rebuild.sh`.

## 3. Restore data (a backup or export) into a rebuilt project

Do this **before anyone signs in with a PIN**:

1. Restore the data. If the backup did not include `app.secrets`, the PIN hashes in it were made with the OLD pepper.
2. Put the saved pepper back: `update app.secrets set value = '<saved value>' where key = 'pin_pepper';`
3. Check it: the fingerprint query in step 0 must return `498bdd10863f`. If it does, old PINs work again.
4. If you do not have the saved pepper: leave the new one and reset each staff PIN from Settings -> Users (a manager can do this).
5. Recreate the vault secrets (step 2.4).

A full Supabase backup or point-in-time restore of the **same** project includes `app.secrets`, so the pepper comes back with it.

## 4. App environment variables (Vercel)

Names only; get the values from the Supabase dashboard, the push provider and Resend. Never put the service-role key anywhere.

| Variable | Needed for |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | everything |
| `NEXT_PUBLIC_SITE_URL` | links in e-bills and QR codes |
| `PUSH_SECRET` | owner alerts and report e-mails (equal to vault `push_secret`) |
| `NEXT_PUBLIC_VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` | owner phone alerts (a key pair; if regenerated, phones must turn alerts on again) |
| `RESEND_API_KEY`, `REPORT_EMAIL_FROM` | scheduled report e-mails |
| `NEXT_PUBLIC_SNA_CONTACT_EMAIL` | the support contact shown in the app |
