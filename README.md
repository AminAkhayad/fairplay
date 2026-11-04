# Fair Play

Futsal matchmaking: when your official opponent forfeits, find another team in your province for a friendly.

- `index.html` – the web app
- `config.js` – your Supabase project URL and publishable key
- `supabase/schema.sql` – the database (tables, security rules, functions)
- `vendor/supabase.js` – Supabase browser library (v2.117.3)

## How it works

- **Accounts** use Supabase Auth. Passwords are hashed with bcrypt by Supabase; the app never stores them.
- **Teams** are real teams that sign up. A team *places* itself on a day; other teams in the same
  province see it on the calendar and can send a **challenge**. The other team **accepts** or **declines**.
- **Open calls**: a team posts "we're looking for an opponent on this day"; other teams respond with "I'm in".
- **Time & place**: every friendly has a kick-off time, who hosts and the hall address (opens in Google Maps — no API key needed).
- **Level & distance**: teams pick their level; the home hall address is converted to coordinates with
  OpenStreetMap (free, no key) so teams are sorted by distance.
- **Chat** is live between the two teams (Supabase Realtime), with browser notifications while the app is open.
- **Results**: one team enters the score, the other confirms or disputes it. No-shows can be reported.
- **Badges** (Fair play, Reliable, Veteran) and a **season overview** (1 Sept – 31 Aug) on the board.
- **Account**: forgot password, change password, delete account (from your own team page).
- After the match day, either team enters the **score**; both teams give each other a **fair play rating** (1–5 stars).
- Security is enforced in the database (Row Level Security): you can only edit your own team, only read
  your own chats, and matches can only change through the functions in `schema.sql`.

## Setup (one time, ~10 minutes)

1. Create a free account and a new project at <https://supabase.com> (region: West EU / Frankfurt or Paris).
2. In the project: **SQL Editor → New query**, paste the whole of `supabase/schema.sql`, click **Run**.
   Run it again after every update of this file — it upgrades the database and keeps all data.
3. Copy the **Project URL** (Project Settings → Data API) and the **Publishable key**
   (Project Settings → API Keys, starts with `sb_publishable_`) into `config.js`.
   Never use the **Secret key** (`sb_secret_...`) in the app.
4. **Authentication → URL Configuration**: set **Site URL** to where the app runs
   (e.g. `https://aminakhayad.github.io/fairplay/`), so the email confirmation link opens the app.
5. Optional while testing: **Authentication → Providers → Email** → turn off *Confirm email*
   so new accounts can log in immediately.

Note: free Supabase projects pause after a week without activity; you can resume them from the dashboard.
