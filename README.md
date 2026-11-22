# Love Garden 🌷
A pastel, mobile-first couple garden MVP. Includes a playable local demo and optional Supabase auth + realtime sync for two accounts.

## Run locally

1. Install Node.js 18+.
2. In this folder run:

   ```bash
   npm install
   npm run dev
   ```

3. Open the URL Vite prints (usually `http://localhost:5173`).

The demo works without an account and saves progress in this browser's local storage. It is a local preview, not cross-device sync.

## Enable shared realtime garden

1. Create a Supabase project.
2. In Supabase SQL Editor, run `supabase/schema.sql`.
3. In Supabase project settings, copy the Project URL and **anon/public publishable key**. Never use a `service_role` key in the browser.
4. Open the app → Garden settings → Configure cloud connection.
5. Save the URL/key, then Sign in / connect partner.
6. Create an account, verify email if Supabase email confirmation is enabled, then sign in.
7. One person chooses **Create our garden + invite**. Send the generated invite code to the other person.
8. The second person signs in and enters the code under **Join partner's garden**.

Realtime updates are enabled for garden, flower and check-in tables in the SQL setup. Database RPCs enforce XP, seed costs, daily check-in uniqueness, anniversary claim limits, and membership checks on the server.

## MVP rules

- 12 garden plots.
- Check-in: +10 XP and +1 seed per account each Jakarta calendar day.
- Both accounts check in: +20 shared bonus XP once per day.
- Plant: +5 XP. Care: +5 XP, once per flower every 24 hours.
- Anniversary: +100 XP, claimable once on the anniversary date per year.
- Growth is based on elapsed real time. Flowers never die from inactivity. Removed flowers do not refund seeds.
- Level progression: each level requires `level × 100 XP`.
- Flower seed costs/growth: Daisy 1/24h, Tulip 1/36h, Rose 2/48h, Lavender 2/60h, Sunflower 3/72h, Cherry Blossom 4/96h.

## Notes / limitations

- Demo mode is browser-local and is not shared. Configure Supabase for the real two-account experience.
- Supabase email confirmation may require the user to verify email before creating or joining a garden.
- The first version uses a simple emoji/pixel-cozy visual treatment; dedicated sprite assets and richer animations can be added later.
- This package is a standalone scaffold because the original repository was not mounted in the current workspace. Merge it into the existing app after reviewing its structure.
