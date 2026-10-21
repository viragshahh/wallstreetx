# Wall Street X

A fictional stock-market simulation app for the Wall Street X event. It uses Supabase for shared data across participant laptops.

## Files
- `index.html`: web application
- `setup.sql`: database schema and starter data
- `netlify.toml`: static deployment settings

## Configure
Set the frontend configuration in `config.js` using the Supabase project URL and publishable key. Never put a Supabase service-role key or secret key in browser code.

## Deployment
Connect this repository to Netlify and deploy from the `main` branch. After commits land, Netlify can automatically redeploy the site.

## Status
Starter implementation; test authentication, realtime updates, trading and admin permissions before the event.
