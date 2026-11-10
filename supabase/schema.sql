-- =====================================================================
--  Fair Play – database schema (Supabase / PostgreSQL)
--
--  Run this in your Supabase project: Dashboard → SQL Editor →
--  New query → paste this whole file → Run.
--  It is safe to run again: it also upgrades a database created with an
--  earlier version of this file, without losing data.
--
--  Accounts live in Supabase Auth (auth.users). Supabase hashes every
--  password with bcrypt; the app never sees or stores a password.
-- =====================================================================

-- ---------- tables ----------------------------------------------------

create table if not exists public.teams (
  id          uuid primary key default gen_random_uuid(),
  owner       uuid not null unique default auth.uid() references auth.users(id) on delete cascade,
  name        text not null check (char_length(btrim(name)) between 1 and 40),
  province    text not null check (province in
                ('oost-vlaanderen','west-vlaanderen','vlaams-brabant','antwerpen','limburg')),
  logo_url    text not null,
  created_at  timestamptz not null default now()
);
alter table public.teams add column if not exists level text;
alter table public.teams add column if not exists hall_address text;
alter table public.teams add column if not exists lat double precision;
alter table public.teams add column if not exists lng double precision;
alter table public.teams drop constraint if exists teams_level_check;
alter table public.teams add constraint teams_level_check check (level is null or level in
  ('recreational','provincial-4','provincial-3','provincial-2','provincial-1','national'));
alter table public.teams drop constraint if exists teams_hall_check;
alter table public.teams add constraint teams_hall_check check (hall_address is null or char_length(hall_address) <= 200);
create unique index if not exists teams_unique_name on public.teams (province, lower(btrim(name)));

create table if not exists public.players (
  id          uuid primary key default gen_random_uuid(),
  team_id     uuid not null references public.teams(id) on delete cascade,
  position    smallint not null check (position between 0 and 13),
  first_name  text not null check (char_length(btrim(first_name)) between 1 and 40),
  last_name   text not null check (char_length(btrim(last_name)) between 1 and 40),
  photo_url   text,
  unique (team_id, position)
);

-- A team that "places" itself on a day is looking for a friendly that day.
create table if not exists public.availability (
  team_id     uuid not null references public.teams(id) on delete cascade,
  day         date not null,
  primary key (team_id, day)
);
create index if not exists availability_day on public.availability (day);

-- Open call: "we are looking for an opponent on this day" – any team can respond.
create table if not exists public.calls (
  id          uuid primary key default gen_random_uuid(),
  team_id     uuid not null references public.teams(id) on delete cascade,
  day         date not null,
  kickoff     time,
  has_hall    boolean not null default false,
  venue       text check (venue is null or char_length(venue) <= 200),
  note        text check (note is null or char_length(note) <= 300),
  status      text not null default 'open' check (status in ('open','closed','cancelled')),
  created_at  timestamptz not null default now()
);
create index if not exists calls_day on public.calls (day, status);

create table if not exists public.matches (
  id                uuid primary key default gen_random_uuid(),
  day               date not null,
  challenger        uuid not null references public.teams(id) on delete cascade,
  opponent          uuid not null references public.teams(id) on delete cascade,
  status            text not null default 'pending',
  challenger_score  smallint check (challenger_score between 0 and 99),
  opponent_score    smallint check (opponent_score between 0 and 99),
  result_by         uuid references public.teams(id) on delete set null,
  created_at        timestamptz not null default now(),
  check (challenger <> opponent)
);
alter table public.matches add column if not exists kickoff time;
alter table public.matches add column if not exists venue text;
alter table public.matches add column if not exists host uuid references public.teams(id) on delete set null;
alter table public.matches add column if not exists call_id uuid references public.calls(id) on delete set null;
alter table public.matches add column if not exists no_show uuid references public.teams(id) on delete set null;
alter table public.matches add column if not exists cancelled_by uuid references public.teams(id) on delete set null;
-- suggested = Fair Play paired two left-over teams; both must accept (confirmed_by = first one that did)
alter table public.matches add column if not exists suggested boolean not null default false;
alter table public.matches add column if not exists confirmed_by uuid references public.teams(id) on delete set null;
alter table public.matches drop constraint if exists matches_status_check;
alter table public.matches add constraint matches_status_check check (status in
  ('pending','accepted','declined','cancelled','result_pending','played','no_show'));
alter table public.matches drop constraint if exists matches_venue_check;
alter table public.matches add constraint matches_venue_check check (venue is null or char_length(venue) <= 200);
create index if not exists matches_challenger on public.matches (challenger, day);
create index if not exists matches_opponent   on public.matches (opponent, day);

-- Fair play rating one team gives the other after a match (1–5 stars).
create table if not exists public.ratings (
  match_id  uuid not null references public.matches(id) on delete cascade,
  rater     uuid not null references public.teams(id) on delete cascade,
  rated     uuid not null references public.teams(id) on delete cascade,
  stars     smallint not null check (stars between 1 and 5),
  created_at timestamptz not null default now(),
  primary key (match_id, rater)
);
create index if not exists ratings_rated on public.ratings (rated);

create table if not exists public.messages (
  id          bigint generated always as identity primary key,
  sender      uuid not null references public.teams(id) on delete cascade,
  recipient   uuid not null references public.teams(id) on delete cascade,
  body        text not null check (char_length(btrim(body)) between 1 and 1000),
  created_at  timestamptz not null default now(),
  read_at     timestamptz,
  check (sender <> recipient)
);
create index if not exists messages_pair on public.messages (sender, recipient, created_at);
create index if not exists messages_inbox on public.messages (recipient, read_at);

-- Goals per player, entered by each team for its own players.
-- player_name is a copy, so the record stays right if the squad changes later.
create table if not exists public.goals (
  id          bigint generated always as identity primary key,
  match_id    uuid not null references public.matches(id) on delete cascade,
  team_id     uuid not null references public.teams(id) on delete cascade,
  player_id   uuid references public.players(id) on delete set null,
  player_name text not null,
  goals       smallint not null check (goals between 1 and 99),
  unique (match_id, player_id)
);
create index if not exists goals_team on public.goals (team_id);
create index if not exists goals_match on public.goals (match_id);

-- One row per account, with its email and an admin switch (0 = normal user, 1 = admin).
-- Make someone admin: Supabase → Table Editor → profiles → set is_admin to 1 on their row.
-- Users can read only their own row and can never change it themselves.
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text,
  is_admin    smallint not null default 0 check (is_admin in (0, 1)),
  created_at  timestamptz not null default now()
);
alter table public.profiles enable row level security;
drop policy if exists profiles_read_own on public.profiles;
create policy profiles_read_own on public.profiles for select to authenticated using (id = auth.uid());

-- every new account gets a profile automatically
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email) values (new.id, new.email)
    on conflict (id) do update set email = excluded.email;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert or update of email on auth.users
  for each row execute function public.handle_new_user();

-- accounts that already existed
insert into public.profiles (id, email) select id, email from auth.users
  on conflict (id) do update set email = excluded.email;

-- (older versions used a separate admins table; it still counts if it exists)
create table if not exists public.admins (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now()
);
alter table public.admins enable row level security;

-- Teams of admin accounts are hidden from the public leaderboards.
create or replace function public.owner_is_admin(p_owner uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = p_owner and is_admin = 1)
      or exists (select 1 from public.admins where user_id = p_owner)
$$;

-- ---------- helper ----------------------------------------------------

-- The team owned by the logged-in user (null when they have none yet).
create or replace function public.my_team() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.teams where owner = auth.uid()
$$;

-- ---------- stats -----------------------------------------------------
-- Public totals per team (only aggregates; individual matches stay private).

drop view if exists public.team_stats;
create view public.team_stats as
select
  t.id as team_id,
  count(m.id) filter (where m.status = 'played')::int as played,
  count(m.id) filter (where m.status = 'played' and (
      (m.challenger = t.id and m.challenger_score > m.opponent_score)
   or (m.opponent   = t.id and m.opponent_score   > m.challenger_score)))::int as won,
  count(m.id) filter (where m.status = 'played' and m.challenger_score = m.opponent_score)::int as drawn,
  count(m.id) filter (where m.status = 'played' and (
      (m.challenger = t.id and m.challenger_score < m.opponent_score)
   or (m.opponent   = t.id and m.opponent_score   < m.challenger_score)))::int as lost,
  count(m.id) filter (where m.status = 'no_show' and m.no_show = t.id)::int as no_shows,
  count(m.id) filter (where m.status = 'cancelled' and m.cancelled_by = t.id)::int as late_cancels,
  (select round(avg(r.stars)::numeric, 2) from public.ratings r where r.rated = t.id) as rating,
  (select count(*)::int from public.ratings r where r.rated = t.id) as rating_count,
  public.owner_is_admin(t.owner) as hidden
from public.teams t
left join public.matches m on t.id in (m.challenger, m.opponent)
group by t.id;
revoke all on public.team_stats from anon, public;
grant select on public.team_stats to authenticated;

-- Season overview for one province (season = 1 Sept – 31 Aug).
create or replace function public.season_stats(p_province text, p_from date, p_to date)
returns table (team_id uuid, name text, logo_url text, played int, won int, drawn int, lost int,
               goals_for int, goals_against int, rating numeric, rating_count int)
language sql stable security definer set search_path = public as $$
  select t.id, t.name, t.logo_url,
    count(m.id)::int,
    count(m.id) filter (where (m.challenger = t.id and m.challenger_score > m.opponent_score)
                           or (m.opponent   = t.id and m.opponent_score   > m.challenger_score))::int,
    count(m.id) filter (where m.challenger_score = m.opponent_score)::int,
    count(m.id) filter (where (m.challenger = t.id and m.challenger_score < m.opponent_score)
                           or (m.opponent   = t.id and m.opponent_score   < m.challenger_score))::int,
    coalesce(sum(case when m.challenger = t.id then m.challenger_score else m.opponent_score end), 0)::int,
    coalesce(sum(case when m.challenger = t.id then m.opponent_score else m.challenger_score end), 0)::int,
    (select round(avg(r.stars)::numeric, 2) from ratings r join matches rm on rm.id = r.match_id
       where r.rated = t.id and rm.day between p_from and p_to),
    (select count(*)::int from ratings r join matches rm on rm.id = r.match_id
       where r.rated = t.id and rm.day between p_from and p_to)
  from teams t
  left join matches m on m.status = 'played' and t.id in (m.challenger, m.opponent)
                     and m.day between p_from and p_to
  where t.province = p_province and auth.uid() is not null and not public.owner_is_admin(t.owner)
  group by t.id
$$;

-- ---------- row level security ---------------------------------------

alter table public.teams        enable row level security;
alter table public.players      enable row level security;
alter table public.availability enable row level security;
alter table public.calls        enable row level security;
alter table public.matches      enable row level security;
alter table public.ratings      enable row level security;
alter table public.messages     enable row level security;

-- teams: every logged-in user can see teams; you can only manage your own
drop policy if exists teams_read   on public.teams;
drop policy if exists teams_insert on public.teams;
drop policy if exists teams_update on public.teams;
drop policy if exists teams_delete on public.teams;
create policy teams_read   on public.teams for select to authenticated using (true);
create policy teams_insert on public.teams for insert to authenticated with check (owner = auth.uid());
create policy teams_update on public.teams for update to authenticated using (owner = auth.uid()) with check (owner = auth.uid());
create policy teams_delete on public.teams for delete to authenticated using (owner = auth.uid());

-- players: visible to all logged-in users; only the team owner edits them
drop policy if exists players_read  on public.players;
drop policy if exists players_write on public.players;
create policy players_read  on public.players for select to authenticated using (true);
create policy players_write on public.players for all    to authenticated
  using (team_id = public.my_team()) with check (team_id = public.my_team());

-- availability: visible to all; you place/remove only your own team,
-- only for today or later, and not on a day you already have a friendly
drop policy if exists avail_read   on public.availability;
drop policy if exists avail_insert on public.availability;
drop policy if exists avail_delete on public.availability;
create policy avail_read   on public.availability for select to authenticated using (true);
create policy avail_insert on public.availability for insert to authenticated with check (
  team_id = public.my_team()
  and day >= current_date
  and not exists (select 1 from public.matches m
                  where m.status = 'accepted' and m.day = availability.day
                    and availability.team_id in (m.challenger, m.opponent)));
create policy avail_delete on public.availability for delete to authenticated using (team_id = public.my_team());

-- open calls: visible to all; you post and manage only your own
drop policy if exists calls_read   on public.calls;
drop policy if exists calls_insert on public.calls;
drop policy if exists calls_update on public.calls;
drop policy if exists calls_delete on public.calls;
create policy calls_read   on public.calls for select to authenticated using (true);
create policy calls_insert on public.calls for insert to authenticated
  with check (team_id = public.my_team() and day >= current_date and status = 'open');
create policy calls_update on public.calls for update to authenticated
  using (team_id = public.my_team()) with check (team_id = public.my_team());
create policy calls_delete on public.calls for delete to authenticated using (team_id = public.my_team());

-- matches: you see your own matches and every played result.
-- Changes only go through the functions below (no insert/update policy).
drop policy if exists matches_read on public.matches;
create policy matches_read on public.matches for select to authenticated
  using (public.my_team() in (challenger, opponent) or status = 'played');

-- ratings: readable by all logged-in users (used for the average)
-- goals: readable by all logged-in users (season top scorers); written only via set_scorers()
alter table public.goals enable row level security;
drop policy if exists goals_read on public.goals;
create policy goals_read on public.goals for select to authenticated using (true);

drop policy if exists ratings_read on public.ratings;
create policy ratings_read on public.ratings for select to authenticated using (true);

-- messages: only the two teams in a conversation can read it;
-- you can only send as your own team
drop policy if exists messages_read   on public.messages;
drop policy if exists messages_insert on public.messages;
create policy messages_read   on public.messages for select to authenticated
  using (public.my_team() in (sender, recipient));
create policy messages_insert on public.messages for insert to authenticated
  with check (sender = public.my_team() and read_at is null);

-- ---------- functions (the only way to change matches) ---------------

drop function if exists public.challenge(uuid, date);

-- Is either team already booked (planned friendly) on this day?
create or replace function public.booked(p_a uuid, p_b uuid, p_day date) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from matches where day = p_day and status in ('accepted','result_pending','played')
                 and (p_a in (challenger, opponent) or p_b in (challenger, opponent)))
$$;

-- Challenge a team that placed itself on a day.
create or replace function public.challenge(p_opponent uuid, p_day date,
  p_kickoff time default null, p_venue text default null, p_host uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_team(); my_prov text; new_id uuid;
begin
  if me is null then raise exception 'Create your team first'; end if;
  if p_opponent = me then raise exception 'You cannot challenge your own team'; end if;
  if p_day < current_date then raise exception 'This day is in the past'; end if;
  if p_host is not null and p_host not in (me, p_opponent) then raise exception 'Invalid host'; end if;
  select province into my_prov from teams where id = me;
  if not exists (select 1 from teams where id = p_opponent and province = my_prov) then
    raise exception 'That team is not in your province';
  end if;
  if not exists (select 1 from availability where team_id = p_opponent and day = p_day) then
    raise exception 'That team is no longer available on this day';
  end if;
  if public.booked(me, p_opponent, p_day) then
    raise exception 'One of the teams already has a friendly on this day';
  end if;
  if exists (select 1 from matches where day = p_day and status = 'pending'
             and ((challenger = me and opponent = p_opponent) or (challenger = p_opponent and opponent = me))) then
    raise exception 'There is already an open request between your teams for this day';
  end if;
  insert into matches (day, challenger, opponent, kickoff, venue, host)
    values (p_day, me, p_opponent, p_kickoff, nullif(btrim(p_venue), ''), p_host)
    returning id into new_id;
  return new_id;
end $$;

-- Respond to an open call: sends a request to the team that posted it.
create or replace function public.respond_to_call(p_call uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_team(); c calls; new_id uuid;
begin
  if me is null then raise exception 'Create your team first'; end if;
  select * into c from calls where id = p_call;
  if c.id is null or c.status <> 'open' then raise exception 'This call is no longer open'; end if;
  if c.team_id = me then raise exception 'This is your own call'; end if;
  if c.day < current_date then raise exception 'This day is in the past'; end if;
  if public.booked(me, c.team_id, c.day) then
    raise exception 'One of the teams already has a friendly on this day';
  end if;
  if exists (select 1 from matches where day = c.day and status = 'pending'
             and ((challenger = me and opponent = c.team_id) or (challenger = c.team_id and opponent = me))) then
    raise exception 'You already responded to this team for this day';
  end if;
  insert into matches (day, challenger, opponent, kickoff, venue, host, call_id)
    values (c.day, me, c.team_id, c.kickoff, c.venue, case when c.has_hall then c.team_id end, c.id)
    returning id into new_id;
  return new_id;
end $$;

-- Accept or decline a challenge you received.
-- For a suggested match (two left-over teams paired by Fair Play) both teams must accept.
-- When a team accepts one of several requests for a day, the teams it did not choose
-- are paired with each other, two by two, as a suggested match.
create or replace function public.respond(p_match uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_team(); m matches; leftover uuid[]; a uuid; b uuid; i int := 1;
begin
  select * into m from matches where id = p_match for update;
  if m.id is null then raise exception 'Request not found'; end if;
  if m.suggested then
    if me is null or me not in (m.challenger, m.opponent) then raise exception 'Request not found'; end if;
  elsif m.opponent is distinct from me then
    raise exception 'Request not found';
  end if;
  if m.status <> 'pending' then raise exception 'This request was already answered or withdrawn'; end if;
  if not p_accept then
    update matches set status = 'declined' where id = p_match;
    return;
  end if;
  if m.day < current_date then raise exception 'This day is in the past'; end if;
  if public.booked(m.challenger, m.opponent, m.day) then
    raise exception 'One of the teams already has a friendly on this day';
  end if;
  if m.suggested and (m.confirmed_by is null or m.confirmed_by = me) then
    update matches set confirmed_by = me where id = p_match;   -- wait for the other team
    return;
  end if;
  update matches set status = 'accepted' where id = p_match;

  -- teams that also wanted to play one of these two teams that day, in order of asking
  select array_agg(x.challenger order by x.first_at) into leftover
  from (select challenger, min(created_at) as first_at from matches
        where day = m.day and status = 'pending' and id <> p_match and not suggested
          and opponent in (m.challenger, m.opponent) and challenger not in (m.challenger, m.opponent)
        group by challenger) x;

  -- both teams are now booked: close their other open requests, calls and day placements
  update matches set status = 'declined'
    where day = m.day and status = 'pending' and id <> p_match
      and (m.challenger in (challenger, opponent) or m.opponent in (challenger, opponent));
  update calls set status = 'closed'
    where day = m.day and status = 'open' and team_id in (m.challenger, m.opponent);
  delete from availability where day = m.day and team_id in (m.challenger, m.opponent);

  -- pair the left-over teams with each other
  while leftover is not null and i < array_length(leftover, 1) loop
    a := leftover[i]; b := leftover[i + 1];
    if not public.booked(a, b, m.day)
       and not exists (select 1 from matches where day = m.day and status = 'pending'
                       and ((challenger = a and opponent = b) or (challenger = b and opponent = a))) then
      insert into matches (day, challenger, opponent, kickoff, suggested) values (m.day, a, b, m.kickoff, true);
      i := i + 2;
    else
      i := i + 1;
    end if;
  end loop;
end $$;

-- Change time / place / host of a request or planned friendly (either team).
create or replace function public.update_match_details(p_match uuid, p_kickoff time, p_venue text, p_host uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_team(); m matches;
begin
  select * into m from matches where id = p_match for update;
  if m.id is null or me not in (m.challenger, m.opponent) then raise exception 'Match not found'; end if;
  if m.status not in ('pending','accepted') then raise exception 'This match can no longer be changed'; end if;
  if p_host is not null and p_host not in (m.challenger, m.opponent) then raise exception 'Invalid host'; end if;
  if char_length(p_venue) > 200 then raise exception 'Address is too long'; end if;
  update matches set kickoff = p_kickoff, venue = nullif(btrim(p_venue), ''), host = p_host where id = p_match;
end $$;

-- Withdraw a request you sent, or cancel a planned friendly.
create or replace function public.cancel_match(p_match uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_team(); m matches;
begin
  select * into m from matches where id = p_match for update;
  if m.id is null or me not in (m.challenger, m.opponent) then raise exception 'Match not found'; end if;
  if m.status = 'pending' and m.challenger <> me and not m.suggested then raise exception 'Decline the request instead'; end if;
  if m.status not in ('pending','accepted') then raise exception 'This match can no longer be cancelled'; end if;
  update matches set status = 'cancelled',
    cancelled_by = case when m.status = 'accepted' then me end   -- withdrawing a request does not count
  where id = p_match;
end $$;

-- Enter the score after the match day. The other team must confirm it.
drop function if exists public.submit_result(uuid, int, int, int);
create or replace function public.submit_result(p_match uuid, p_my_score int, p_their_score int, p_stars int)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_team(); m matches; other uuid;
begin
  select * into m from matches where id = p_match for update;
  if m.id is null or me not in (m.challenger, m.opponent) then raise exception 'Match not found'; end if;
  if m.day > current_date then raise exception 'You can enter the result after the match day'; end if;
  if p_stars not between 1 and 5 then raise exception 'Rating must be 1 to 5 stars'; end if;
  if p_my_score not between 0 and 99 or p_their_score not between 0 and 99 then raise exception 'Invalid score'; end if;
  other := case when m.challenger = me then m.opponent else m.challenger end;
  if m.status = 'accepted' or (m.status = 'result_pending' and m.result_by = me) then
    update matches set status = 'result_pending', result_by = me,
      challenger_score = case when m.challenger = me then p_my_score else p_their_score end,
      opponent_score   = case when m.challenger = me then p_their_score else p_my_score end
    where id = p_match;
    delete from goals where match_id = p_match;   -- score (re)entered: scorers are entered again after it
  elsif m.status = 'result_pending' then
    raise exception 'The other team already entered a score. Confirm or dispute it.';
  elsif m.status <> 'played' then
    raise exception 'This match was not played';
  end if;
  insert into ratings (match_id, rater, rated, stars) values (p_match, me, other, p_stars)
    on conflict (match_id, rater) do update set stars = excluded.stars;
end $$;

-- Confirm the score the other team entered (and rate them).
create or replace function public.confirm_result(p_match uuid, p_stars int) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_team(); m matches; other uuid;
begin
  select * into m from matches where id = p_match for update;
  if m.id is null or me not in (m.challenger, m.opponent) then raise exception 'Match not found'; end if;
  if m.status <> 'result_pending' or m.result_by = me then raise exception 'There is no score to confirm'; end if;
  if p_stars not between 1 and 5 then raise exception 'Rating must be 1 to 5 stars'; end if;
  other := case when m.challenger = me then m.opponent else m.challenger end;
  update matches set status = 'played' where id = p_match;
  insert into ratings (match_id, rater, rated, stars) values (p_match, me, other, p_stars)
    on conflict (match_id, rater) do update set stars = excluded.stars;
end $$;

-- Reject the score the other team entered: back to "planned", score cleared.
create or replace function public.dispute_result(p_match uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_team(); m matches;
begin
  select * into m from matches where id = p_match for update;
  if m.id is null or me not in (m.challenger, m.opponent) then raise exception 'Match not found'; end if;
  if m.status <> 'result_pending' or m.result_by = me then raise exception 'There is no score to dispute'; end if;
  update matches set status = 'accepted', result_by = null, challenger_score = null, opponent_score = null
    where id = p_match;
  delete from goals where match_id = p_match;
end $$;

-- The other team did not turn up.
create or replace function public.report_no_show(p_match uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_team(); m matches;
begin
  select * into m from matches where id = p_match for update;
  if m.id is null or me not in (m.challenger, m.opponent) then raise exception 'Match not found'; end if;
  if m.status <> 'accepted' then raise exception 'You can only report a planned friendly'; end if;
  if m.day > current_date then raise exception 'You can report a no-show from the match day on'; end if;
  update matches set status = 'no_show', result_by = me,
    no_show = case when m.challenger = me then m.opponent else m.challenger end
  where id = p_match;
end $$;

-- Save who scored for your team in a match: [{"player_id": "...", "goals": 2}, ...]
-- Replaces what you entered before. Total may not exceed your team's score.
create or replace function public.set_scorers(p_match uuid, p_scorers jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_team(); m matches; my_score int; total int;
begin
  select * into m from matches where id = p_match for update;
  if m.id is null or me not in (m.challenger, m.opponent) then raise exception 'Match not found'; end if;
  if m.status not in ('result_pending','played') then raise exception 'Enter the score first'; end if;
  my_score := case when m.challenger = me then m.challenger_score else m.opponent_score end;
  if jsonb_typeof(p_scorers) <> 'array' then raise exception 'Invalid scorers'; end if;
  if exists (select 1 from jsonb_array_elements(p_scorers) e
             where not exists (select 1 from players pl where pl.id = (e->>'player_id')::uuid and pl.team_id = me)) then
    raise exception 'You can only add players of your own team';
  end if;
  select coalesce(sum((e->>'goals')::int), 0) into total from jsonb_array_elements(p_scorers) e;
  if total > my_score then raise exception 'You entered % goals for players, but your team scored %', total, my_score; end if;
  delete from goals where match_id = p_match and team_id = me;
  insert into goals (match_id, team_id, player_id, player_name, goals)
    select p_match, me, pl.id, pl.first_name || ' ' || pl.last_name, (e->>'goals')::int
    from jsonb_array_elements(p_scorers) e join players pl on pl.id = (e->>'player_id')::uuid
    where (e->>'goals')::int > 0;
end $$;

-- Top scorers of a province in a season (only matches confirmed by both teams).
create or replace function public.season_scorers(p_province text, p_from date, p_to date, p_limit int default 10)
returns table (player_id uuid, player_name text, photo_url text, team_id uuid, team_name text, team_logo text, goals int)
language sql stable security definer set search_path = public as $$
  select g.player_id, coalesce(pl.first_name || ' ' || pl.last_name, g.player_name), pl.photo_url,
         t.id, t.name, t.logo_url, sum(g.goals)::int
  from goals g
  join matches m on m.id = g.match_id and m.status = 'played' and m.day between p_from and p_to
  join teams t on t.id = g.team_id and t.province = p_province and not public.owner_is_admin(t.owner)
  left join players pl on pl.id = g.player_id
  where auth.uid() is not null
  group by g.player_id, coalesce(pl.first_name || ' ' || pl.last_name, g.player_name), pl.photo_url, t.id, t.name, t.logo_url
  order by sum(g.goals) desc, 2
  limit least(greatest(p_limit, 1), 50)
$$;

-- ---------- push notifications -------------------------------------
-- One row per phone/browser that turned on notifications. The Edge Function
-- "notify" (supabase/functions/notify) reads these to send push messages.
create table if not exists public.push_subscriptions (
  endpoint    text primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  p256dh      text not null,
  auth        text not null,
  created_at  timestamptz not null default now()
);
create index if not exists push_subscriptions_user on public.push_subscriptions (user_id);
alter table public.push_subscriptions enable row level security;
drop policy if exists push_read_own on public.push_subscriptions;
create policy push_read_own on public.push_subscriptions for select to authenticated using (user_id = auth.uid());

-- Save this device for the logged-in user (a shared phone moves to whoever logged in last).
create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not logged in'; end if;
  if p_endpoint !~ '^https://' or char_length(p_endpoint) > 1000 then raise exception 'Invalid subscription'; end if;
  insert into push_subscriptions (endpoint, user_id, p256dh, auth) values (p_endpoint, auth.uid(), p_p256dh, p_auth)
    on conflict (endpoint) do update set user_id = auth.uid(), p256dh = excluded.p256dh, auth = excluded.auth;
end $$;

-- Stop notifications on this device (e.g. when logging out).
create or replace function public.remove_push_subscription(p_endpoint text) returns void
language sql security definer set search_path = public as $$
  delete from push_subscriptions where endpoint = p_endpoint and user_id = auth.uid()
$$;

-- ---------- admin ----------------------------------------------------

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and is_admin = 1)
      or exists (select 1 from public.admins where user_id = auth.uid())
$$;

-- Overview for the admin page. "Bookings" = friendlies that went ahead
-- (accepted, score pending or played), counted on the match day.
create or replace function public.admin_stats(p_months int default 12) returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
declare
  months int := least(greatest(coalesce(p_months, 12), 1), 36);
  first_month date := (date_trunc('month', current_date) - make_interval(months => months - 1))::date;
  r jsonb;
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  with b as (
    select m.*, coalesce(nullif(btrim(m.venue), ''), h.hall_address) as hall
    from matches m left join teams h on h.id = m.host
    where m.status in ('accepted', 'result_pending', 'played')
  ), bp as (select * from b where day >= first_month)
  select jsonb_build_object(
    'kpis', jsonb_build_object(
      'users',            (select count(*) from auth.users),
      'teams',            (select count(*) from teams),
      'teams_new_month',  (select count(*) from teams where created_at >= date_trunc('month', now())),
      'bookings_total',   (select count(*) from b),
      'bookings_month',   (select count(*) from b where date_trunc('month', day) = date_trunc('month', current_date)),
      'bookings_prev',    (select count(*) from b where date_trunc('month', day) = date_trunc('month', current_date) - interval '1 month'),
      'upcoming',         (select count(*) from b where day >= current_date),
      'accept_rate',      (select round(100.0 * count(*) filter (where status in ('accepted','result_pending','played','no_show'))
                                   / nullif(count(*) filter (where status in ('accepted','result_pending','played','no_show','declined')), 0), 1) from matches),
      'no_show_rate',     (select round(100.0 * count(*) filter (where status = 'no_show')
                                   / nullif(count(*) filter (where status in ('played','no_show')), 0), 1) from matches),
      'cancel_rate',      (select round(100.0 * count(*) filter (where status = 'cancelled' and cancelled_by is not null)
                                   / nullif(count(*) filter (where status in ('accepted','result_pending','played','no_show')
                                                            or (status = 'cancelled' and cancelled_by is not null)), 0), 1) from matches),
      'open_calls',       (select count(*) from calls where status = 'open' and day >= current_date),
      'calls_filled_rate',(select round(100.0 * count(*) filter (where status = 'closed')
                                   / nullif(count(*) filter (where status = 'closed' or (status <> 'open') or day < current_date), 0), 1) from calls),
      'suggested_matches',(select count(*) from matches where suggested),
      'suggested_accepted',(select count(*) from matches where suggested and status in ('accepted','result_pending','played')),
      'bookings_no_hall', (select count(*) from bp where hall is null)
    ),
    'per_month', (select jsonb_agg(jsonb_build_object(
                    'month', to_char(mo, 'YYYY-MM'),
                    'bookings', (select count(*) from b where date_trunc('month', b.day) = mo),
                    'new_teams', (select count(*) from teams t where date_trunc('month', t.created_at) = mo)) order by mo)
                  from generate_series(first_month::timestamp, date_trunc('month', current_date)::timestamp, interval '1 month') mo),
    'per_weekday', (select jsonb_agg(jsonb_build_object('dow', d, 'bookings',
                      (select count(*) from bp where extract(isodow from bp.day) = d)) order by d)
                    from generate_series(1, 7) d),
    'per_hour', (select coalesce(jsonb_agg(jsonb_build_object('hour', h, 'bookings', n) order by h), '[]'::jsonb)
                 from (select extract(hour from kickoff)::int h, count(*) n from bp where kickoff is not null group by 1) x),
    'halls', (select coalesce(jsonb_agg(jsonb_build_object('hall', name, 'bookings', n, 'teams', tm) order by n desc, name), '[]'::jsonb)
              from (select min(hall) name, count(*) n,
                           (select count(distinct t) from unnest(array_agg(challenger) || array_agg(opponent)) t) tm
                    from bp where hall is not null group by lower(btrim(hall)) order by count(*) desc limit 10) x),
    'per_province', (select jsonb_agg(jsonb_build_object('province', p, 'teams', tc, 'bookings', bc) order by bc desc, tc desc)
                     from (select t.province p, count(distinct t.id) tc, count(distinct bp.id) bc
                           from teams t left join bp on t.id in (bp.challenger, bp.opponent) group by 1) x),
    'per_level', (select jsonb_agg(jsonb_build_object('level', l, 'teams', tc, 'bookings', bc) order by bc desc, tc desc)
                  from (select coalesce(t.level, 'unknown') l, count(distinct t.id) tc, count(distinct bp.id) bc
                        from teams t left join bp on t.id in (bp.challenger, bp.opponent) group by 1) x),
    'top_teams', (select coalesce(jsonb_agg(jsonb_build_object('name', name, 'province', province, 'bookings', n) order by n desc, name), '[]'::jsonb)
                  from (select t.name, t.province, count(*) n from bp join teams t on t.id in (bp.challenger, bp.opponent)
                        group by t.id, t.name, t.province order by n desc limit 10) x),
    'recent', (select coalesce(jsonb_agg(jsonb_build_object('day', day, 'status', status, 'suggested', suggested,
                       'challenger', c, 'opponent', o, 'created_at', created_at) order by created_at desc), '[]'::jsonb)
               from (select m.day, m.status, m.suggested, m.created_at, tc.name c, tor.name o
                     from matches m join teams tc on tc.id = m.challenger join teams tor on tor.id = m.opponent
                     order by m.created_at desc limit 12) x)
  ) into r;
  return r;
end $$;

-- Mark the messages another team sent you as read.
create or replace function public.mark_read(p_from uuid) returns void
language sql security definer set search_path = public as $$
  update messages set read_at = now()
  where recipient = public.my_team() and sender = p_from and read_at is null
$$;

-- Delete your own account. Your team, players, chats and matches are removed with it.
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'Not logged in'; end if;
  delete from auth.users where id = auth.uid();
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.booked(uuid, uuid, date)',
    'public.challenge(uuid, date, time, text, uuid)',
    'public.respond_to_call(uuid)',
    'public.respond(uuid, boolean)',
    'public.update_match_details(uuid, time, text, uuid)',
    'public.cancel_match(uuid)',
    'public.submit_result(uuid, int, int, int)',
    'public.confirm_result(uuid, int)',
    'public.dispute_result(uuid)',
    'public.report_no_show(uuid)',
    'public.mark_read(uuid)',
    'public.delete_my_account()',
    'public.season_stats(text, date, date)',
    'public.set_scorers(uuid, jsonb)',
    'public.season_scorers(text, date, date, int)',
    'public.is_admin()',
    'public.save_push_subscription(text, text, text)',
    'public.remove_push_subscription(text)',
    'public.admin_stats(int)']
  loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- ---------- photo storage --------------------------------------------
-- Public bucket for team logos and player photos. Each user may only
-- upload into a folder named after their own user id.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('media', 'media', true, 2097152, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

-- (Storage reads the new row back during an upload, so a select policy is
--  needed as well as insert; the bucket is public, so this reveals nothing extra.)
drop policy if exists media_select on storage.objects;
drop policy if exists media_insert on storage.objects;
drop policy if exists media_update on storage.objects;
drop policy if exists media_delete on storage.objects;
create policy media_select on storage.objects for select to authenticated
  using (bucket_id = 'media');
create policy media_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);
create policy media_update on storage.objects for update to authenticated
  using (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);
create policy media_delete on storage.objects for delete to authenticated
  using (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------- realtime (live chat and match updates) -------------------

do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'messages') then
    alter publication supabase_realtime add table public.messages;
  end if;
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'matches') then
    alter publication supabase_realtime add table public.matches;
  end if;
end $$;
