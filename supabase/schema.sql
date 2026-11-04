-- =====================================================================
--  Fair Play – database schema (Supabase / PostgreSQL)
--
--  Run this once in your Supabase project: Dashboard → SQL Editor →
--  New query → paste this whole file → Run. It is safe to run again.
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

create table if not exists public.matches (
  id                uuid primary key default gen_random_uuid(),
  day               date not null,
  challenger        uuid not null references public.teams(id) on delete cascade,
  opponent          uuid not null references public.teams(id) on delete cascade,
  status            text not null default 'pending'
                    check (status in ('pending','accepted','declined','cancelled','played')),
  challenger_score  smallint check (challenger_score between 0 and 99),
  opponent_score    smallint check (opponent_score between 0 and 99),
  result_by         uuid references public.teams(id) on delete set null,
  created_at        timestamptz not null default now(),
  check (challenger <> opponent)
);
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

-- ---------- helper ----------------------------------------------------

-- The team owned by the logged-in user (null when they have none yet).
create or replace function public.my_team() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.teams where owner = auth.uid()
$$;

-- ---------- stats view ------------------------------------------------

create or replace view public.team_stats with (security_invoker = on) as
select
  t.id as team_id,
  count(m.id)::int as played,
  count(m.id) filter (where (m.challenger = t.id and m.challenger_score > m.opponent_score)
                         or (m.opponent   = t.id and m.opponent_score   > m.challenger_score))::int as won,
  count(m.id) filter (where m.challenger_score = m.opponent_score)::int as drawn,
  count(m.id) filter (where (m.challenger = t.id and m.challenger_score < m.opponent_score)
                         or (m.opponent   = t.id and m.opponent_score   < m.challenger_score))::int as lost,
  (select round(avg(r.stars)::numeric, 2) from public.ratings r where r.rated = t.id) as rating,
  (select count(*)::int from public.ratings r where r.rated = t.id) as rating_count
from public.teams t
left join public.matches m
  on m.status = 'played' and t.id in (m.challenger, m.opponent)
group by t.id;

-- ---------- row level security ---------------------------------------

alter table public.teams        enable row level security;
alter table public.players      enable row level security;
alter table public.availability enable row level security;
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

-- matches: you see your own matches and every played result.
-- Changes only go through the functions below (no insert/update policy).
drop policy if exists matches_read on public.matches;
create policy matches_read on public.matches for select to authenticated
  using (public.my_team() in (challenger, opponent) or status = 'played');

-- ratings: readable by all logged-in users (used for the average)
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

-- Challenge a team that placed itself on a day.
create or replace function public.challenge(p_opponent uuid, p_day date) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_team(); my_prov text; new_id uuid;
begin
  if me is null then raise exception 'Create your team first'; end if;
  if p_opponent = me then raise exception 'You cannot challenge your own team'; end if;
  if p_day < current_date then raise exception 'This day is in the past'; end if;
  select province into my_prov from teams where id = me;
  if not exists (select 1 from teams where id = p_opponent and province = my_prov) then
    raise exception 'That team is not in your province';
  end if;
  if not exists (select 1 from availability where team_id = p_opponent and day = p_day) then
    raise exception 'That team is no longer available on this day';
  end if;
  if exists (select 1 from matches where day = p_day and status = 'accepted'
             and (me in (challenger, opponent) or p_opponent in (challenger, opponent))) then
    raise exception 'One of the teams already has a friendly on this day';
  end if;
  if exists (select 1 from matches where day = p_day and status = 'pending'
             and ((challenger = me and opponent = p_opponent) or (challenger = p_opponent and opponent = me))) then
    raise exception 'There is already an open request between your teams for this day';
  end if;
  insert into matches (day, challenger, opponent) values (p_day, me, p_opponent) returning id into new_id;
  return new_id;
end $$;

-- Accept or decline a challenge you received.
create or replace function public.respond(p_match uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_team(); m matches;
begin
  select * into m from matches where id = p_match for update;
  if m.id is null or m.opponent is distinct from me then raise exception 'Request not found'; end if;
  if m.status <> 'pending' then raise exception 'This request was already answered or withdrawn'; end if;
  if not p_accept then
    update matches set status = 'declined' where id = p_match;
    return;
  end if;
  if m.day < current_date then raise exception 'This day is in the past'; end if;
  if exists (select 1 from matches where day = m.day and status = 'accepted'
             and (m.challenger in (challenger, opponent) or m.opponent in (challenger, opponent))) then
    raise exception 'One of the teams already has a friendly on this day';
  end if;
  update matches set status = 'accepted' where id = p_match;
  -- both teams are now booked: close their other open requests and remove them from the day
  update matches set status = 'declined'
    where day = m.day and status = 'pending' and id <> p_match
      and (m.challenger in (challenger, opponent) or m.opponent in (challenger, opponent));
  delete from availability where day = m.day and team_id in (m.challenger, m.opponent);
end $$;

-- Withdraw a request you sent, or cancel a planned friendly.
create or replace function public.cancel_match(p_match uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_team(); m matches;
begin
  select * into m from matches where id = p_match for update;
  if m.id is null or me not in (m.challenger, m.opponent) then raise exception 'Match not found'; end if;
  if m.status = 'pending' and m.challenger <> me then raise exception 'Decline the request instead'; end if;
  if m.status not in ('pending','accepted') then raise exception 'This match can no longer be cancelled'; end if;
  update matches set status = 'cancelled' where id = p_match;
end $$;

-- Enter the score (first team to do so sets it) and rate the opponent.
create or replace function public.submit_result(p_match uuid, p_my_score int, p_their_score int, p_stars int)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := public.my_team(); m matches; other uuid;
begin
  select * into m from matches where id = p_match for update;
  if m.id is null or me not in (m.challenger, m.opponent) then raise exception 'Match not found'; end if;
  if m.status not in ('accepted','played') then raise exception 'This match was not played'; end if;
  if m.day > current_date then raise exception 'You can enter the result after the match day'; end if;
  if p_stars not between 1 and 5 then raise exception 'Rating must be 1 to 5 stars'; end if;
  other := case when m.challenger = me then m.opponent else m.challenger end;
  if m.status = 'accepted' then
    if p_my_score not between 0 and 99 or p_their_score not between 0 and 99 then
      raise exception 'Invalid score';
    end if;
    update matches set status = 'played', result_by = me,
      challenger_score = case when m.challenger = me then p_my_score else p_their_score end,
      opponent_score   = case when m.challenger = me then p_their_score else p_my_score end
    where id = p_match;
  end if;
  insert into ratings (match_id, rater, rated, stars) values (p_match, me, other, p_stars)
    on conflict (match_id, rater) do update set stars = excluded.stars;
end $$;

-- Mark the messages another team sent you as read.
create or replace function public.mark_read(p_from uuid) returns void
language sql security definer set search_path = public as $$
  update messages set read_at = now()
  where recipient = public.my_team() and sender = p_from and read_at is null
$$;

revoke execute on function public.challenge(uuid, date)              from public, anon;
revoke execute on function public.respond(uuid, boolean)             from public, anon;
revoke execute on function public.cancel_match(uuid)                 from public, anon;
revoke execute on function public.submit_result(uuid, int, int, int) from public, anon;
revoke execute on function public.mark_read(uuid)                    from public, anon;
grant  execute on function public.challenge(uuid, date)              to authenticated;
grant  execute on function public.respond(uuid, boolean)             to authenticated;
grant  execute on function public.cancel_match(uuid)                 to authenticated;
grant  execute on function public.submit_result(uuid, int, int, int) to authenticated;
grant  execute on function public.mark_read(uuid)                    to authenticated;

-- ---------- photo storage --------------------------------------------
-- Public bucket for team logos and player photos. Each user may only
-- upload into a folder named after their own user id.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('media', 'media', true, 2097152, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

drop policy if exists media_insert on storage.objects;
drop policy if exists media_delete on storage.objects;
create policy media_insert on storage.objects for insert to authenticated
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
