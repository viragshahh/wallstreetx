# Deploy Wall Street X with Netlify

1. Open https://app.netlify.com/ and choose **Add new site → Import an existing project**.
2. Connect GitHub and choose `viragshahh/wallstreetx`.
3. Use branch `main`, build command blank, publish directory `.`.
4. Deploy the site. Netlify will automatically redeploy future commits to `main`.

## Verify before event day
- Open the site URL and confirm the connection status shows connected.
- In Supabase Authentication, create an admin user and grant the user the `admin` role in `public.user_roles`.
- Create recorder users and grant the `recorder` role.
- Confirm realtime is enabled for the tables used by the dashboard.
- Test on at least two separate laptops: publish news, record a trade, verify share prices, transactions, cash and holdings update on both screens.
- Run a low-risk rehearsal and reset teams/data before the event.

## Security
The frontend uses a Supabase publishable key, which is designed for public clients. Row-level security and server-side functions must enforce authorization. Never expose a service-role key or secret key.
