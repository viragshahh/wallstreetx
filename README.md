# Wall Street X — Shared Multi-Laptop App

This package is the source for a browser-based event trading simulator intended for 10+ laptops. It uses Supabase for shared storage, database-enforced roles, atomic trade execution and realtime updates.

## Files
- `index.html` — Dashboard, Recorder and Admin views.
- `setup.sql` — database schema, security policies, atomic trade function, hidden-news functions and fictional starter data.
- `config.js.sample` — configuration example.

## Important setup requirement
This is not a local-only HTML demo. The same deployed URL must be opened on every laptop, and the app must be connected to a Supabase project. The database is the shared source of truth.

## Setup
1. Create or select an active Supabase project. In Supabase, open **SQL Editor** and run the complete `setup.sql`.
2. In **Project Settings → API**, copy the Project URL and the publishable key (or legacy anon key). Never use the service-role/secret key in a browser.
3. Open `index.html` and replace the two values in the `CONFIG` object near the bottom:
   - `PASTE_SUPABASE_PROJECT_URL_HERE`
   - `PASTE_SUPABASE_PUBLISHABLE_OR_ANON_KEY_HERE`
4. Host the folder as a static website (for example, Netlify, Vercel, GitHub Pages or another HTTPS static host). Do not have each laptop open its own file copy; every laptop must use the same hosted URL.
5. In Supabase **Authentication → Users**, create an admin login with email and password. Copy the user UUID, then in SQL Editor run:
   ```sql
   insert into public.user_roles(user_id, role)
   values ('PASTE-ADMIN-USER-UUID-HERE', 'admin')
   on conflict(user_id) do update set role='admin';
   ```
6. Create one account per recorder in Authentication → Users. Assign each the `recorder` role:
   ```sql
   insert into public.user_roles(user_id, role)
   values ('PASTE-RECORDER-USER-UUID-HERE', 'recorder')
   on conflict(user_id) do update set role='recorder';
   ```
7. Sign in from each recorder laptop. Dashboard is public; recorder requires a recorder/admin account; Admin view requires admin role.
8. Before the event, test on two devices: open Round 1, make a test trade, check both teams' cash/holdings and both devices' dashboards. Then reset the test data using admin tools or a fresh database.

## Event rules implemented
- Three rounds; only the active round accepts transactions.
- Five fictional shares are seeded.
- Three demo teams are seeded; admin can add teams.
- Twelve prewritten fictional news drafts are seeded, four per round. Each round has one definitely positive (+8%), one definitely negative (-8%), one somewhat positive (0%), and one somewhat negative (0%). The public sees only the headline/body until admin resolves the event. Hidden classification and impact are stored in the admin-only `news_events` table.
- Admin publishes a headline first, then resolves it separately. Resolving applies its hidden price adjustment if nonzero.
- Recorder transaction writes are performed by a server-side SQL function in one database transaction, with team locks and validation. Buyer cash and seller shares are checked before the trade is committed.

## Security notes
- Do not put a service-role key in the HTML.
- Admin role is assigned in the database, not via a client-side password constant.
- Use HTTPS hosting.
- The app uses public read access for market, team balances and transaction ledger so the event dashboard can display them. If you do not want team financials visible to participants, adjust the policies and app views before the event.
- The initial admin password is not set in this package. You create it through Supabase Auth, then grant the account the admin role.
- News outcomes are kept in a separate table with admin-only row-level security. Do not grant anonymous access to `news_events`.

## Current limits / checks before use
- This package is prepared but not connected to a Supabase project or deployed for you yet.
- `index.html` is a starter implementation. Admin correction UI currently provides an audit view, not a one-click reversal; corrections should be implemented as compensating transactions before a high-stakes event.
- Team holdings are tracked as a JSON object by symbol. Seeded teams begin with cash and no shares; to trade, a selling team must first acquire shares in an earlier transaction. If your event expects every team to begin with shares, seed initial holdings before the event.
- The application uses simulated prices only, not real-world exchange feeds.