# HIVE Event Dashboard

Reusable event operations dashboard for HIVE. The published static interface uses Supabase Auth for shared accounts, Supabase Postgres with row-level security for workspace data, and a shared audit trail.

## Supabase setup (free tier)

1. In Supabase, open **SQL Editor** and run the complete `supabase/setup.sql` file once. The script blocks public self-signup.
2. In SQL Editor, replace `owner@example.com` in the one-time owner invite at the bottom of the script with the invited owner’s email, then run that statement.
3. Open the dashboard URL and create the owner account using that invited email.
4. Confirm the account email if Supabase asks for confirmation.
5. In Supabase SQL Editor, promote that owner account to admin, replacing the email:

   ```sql
   update public.hive_profiles
   set role = 'admin'
   where email = 'owner@example.com';
   ```

6. Return to the dashboard and sign in. The first admin sign-in imports this browser's existing event data when the shared workspace is empty.
7. Admins can add other users from **Users & Audit Log**. Invitees sign up with the invited email and set their own password. Editors can edit event records; viewers have read-only access.

The browser app contains only the Supabase publishable key. Database access is restricted with row-level security. Never place a Supabase secret or service-role key in this repository.

## Existing local data

The first admin login seeds the shared workspace from the event data stored in that browser. Other browser-local copies are not automatically merged. Existing local passwords are not migrated; each user creates a Supabase account through sign-up.
