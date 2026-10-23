-- TapVerse: oyuncular, oyun bazlı haftalık/tüm zaman skorlar, benzersiz isim, admin paneli
-- Supabase > SQL Editor'e yapıştırıp çalıştır. (Birden fazla kez çalıştırmak güvenli.)
-- EN SONDA admin şifreni belirle (dosyanın en altındaki satır).

create extension if not exists pgcrypto with schema extensions;

-- ---------- Tablolar ----------
create table if not exists public.tv_players (
  player_id  text primary key,
  name       text not null,
  name_key   text generated always as (lower(regexp_replace(name, '\s+', '', 'g'))) stored,
  device     jsonb not null default '{}'::jsonb,
  banned     boolean not null default false,
  created_at timestamptz not null default now(),
  last_seen  timestamptz not null default now()
);
create unique index if not exists tv_players_name_key_uq on public.tv_players(name_key);

-- week = 0 -> tüm zamanların rekoru, week > 0 -> o haftanın rekoru
create table if not exists public.tv_records (
  player_id  text not null references public.tv_players(player_id) on delete cascade,
  game       text not null,
  week       integer not null,
  score      integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key (player_id, game, week)
);
create index if not exists tv_records_board on public.tv_records(game, week, score desc);

create table if not exists public.tv_admin (
  id           integer primary key default 1,
  hash         text,
  fails        integer not null default 0,
  locked_until timestamptz,
  check (id = 1)
);

-- Tablolara dışarıdan doğrudan erişim yok; her şey aşağıdaki fonksiyonlardan geçer
alter table public.tv_players enable row level security;
alter table public.tv_records enable row level security;
alter table public.tv_admin   enable row level security;
revoke all on public.tv_players, public.tv_records, public.tv_admin from anon, authenticated;

-- Eski skor tablosundaki oyuncuları taşı (Sonsuz Koşu rekorları)
insert into public.tv_players (player_id, name)
  select player_id, name from public.tapverse_scores
  on conflict do nothing;
insert into public.tv_records (player_id, game, week, score)
  select s.player_id, 'run', 0, s.score from public.tapverse_scores s
  join public.tv_players p on p.player_id = s.player_id
  on conflict do nothing;

-- ---------- Yardımcılar ----------
-- Hafta numarası: Pazartesi 00:00 (UTC) = Türkiye saatiyle 03:00'te yenilenir
create or replace function public.tv_week() returns integer
language sql stable as $$
  select (((now() at time zone 'utc')::date - date '2025-01-06') / 7)::integer
$$;

create or replace function public.tv_clean_name(p text) returns text
language plpgsql immutable as $$
declare n text;
begin
  n := btrim(regexp_replace(coalesce(p, ''), '\s+', ' ', 'g'));
  if char_length(n) < 3 or char_length(n) > 14 then return null; end if;
  if n !~ '^[[:alnum:] _.-]+$' then return null; end if;
  if lower(n) ~ '(admin|tapverse|moderator|yonetici)' then return null; end if;
  return n;
end $$;

-- ---------- Oyuncu: kayıt / isim değiştirme ----------
create or replace function public.tv_register(p_player_id text, p_name text, p_device jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare n text; base text; sug text[] := '{}'; i integer := 0; cand text;
begin
  if p_player_id is null or length(p_player_id) < 8 or length(p_player_id) > 64 then
    return jsonb_build_object('ok', false, 'err', 'id');
  end if;
  n := public.tv_clean_name(p_name);
  if n is null then return jsonb_build_object('ok', false, 'err', 'invalid'); end if;
  if length(coalesce(p_device::text, '')) > 2000 then p_device := '{}'::jsonb; end if;

  if exists (select 1 from public.tv_players
             where name_key = lower(regexp_replace(n, '\s+', '', 'g')) and player_id <> p_player_id) then
    base := left(regexp_replace(n, '[0-9]+$', ''), 11);
    if char_length(base) < 2 then base := 'Oyuncu'; end if;
    while array_length(sug, 1) is null or array_length(sug, 1) < 3 loop
      i := i + 1; exit when i > 999;
      cand := base || lpad(i::text, 3, '0');
      if not exists (select 1 from public.tv_players where name_key = lower(cand)) then
        sug := sug || cand;
      end if;
    end loop;
    return jsonb_build_object('ok', false, 'err', 'taken', 'suggest', to_jsonb(sug));
  end if;

  begin
    insert into public.tv_players (player_id, name, device)
    values (p_player_id, n, coalesce(p_device, '{}'::jsonb))
    on conflict (player_id) do update
      set name = excluded.name,
          device = case when excluded.device = '{}'::jsonb then public.tv_players.device else excluded.device end,
          last_seen = now();
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'err', 'taken', 'suggest', '[]'::jsonb);
  end;
  return jsonb_build_object('ok', true, 'name', n);
end $$;

-- ---------- Oyuncu: skor gönderme ----------
-- p_week_score: bu haftaki en iyi (seviye oyunlarında bu hafta ilerlenen seviye), p_all_score: tüm zamanların rekoru
create or replace function public.tv_submit(p_player_id text, p_game text, p_week_score integer, p_all_score integer)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare banned_ boolean; w integer := public.tv_week();
begin
  if p_game is null or p_game !~ '^[a-z0-9_]{1,20}$' then return jsonb_build_object('ok', false, 'err', 'game'); end if;
  if p_week_score is null or p_all_score is null
     or p_week_score < 0 or p_week_score > 5000000 or p_all_score < 0 or p_all_score > 5000000 then
    return jsonb_build_object('ok', false, 'err', 'score');
  end if;
  select banned into banned_ from public.tv_players where player_id = p_player_id;
  if not found then return jsonb_build_object('ok', false, 'err', 'noplayer'); end if;
  update public.tv_players set last_seen = now() where player_id = p_player_id;
  if banned_ then return jsonb_build_object('ok', true); end if;

  if p_week_score > 0 then
    insert into public.tv_records (player_id, game, week, score) values (p_player_id, p_game, w, p_week_score)
    on conflict (player_id, game, week) do update
      set score = greatest(public.tv_records.score, excluded.score), updated_at = now();
  end if;
  if p_all_score > 0 then
    insert into public.tv_records (player_id, game, week, score) values (p_player_id, p_game, 0, p_all_score)
    on conflict (player_id, game, week) do update
      set score = greatest(public.tv_records.score, excluded.score), updated_at = now();
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Oyuncu: skor tablosu (ilk 20 + kendi sıran) ----------
create or replace function public.tv_top(p_player_id text, p_game text, p_mode text default 'week', p_limit integer default 20)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare w integer; res jsonb; secs bigint;
begin
  w := case when p_mode = 'all' then 0 else public.tv_week() end;
  p_limit := least(greatest(coalesce(p_limit, 20), 1), 50);
  secs := extract(epoch from (date_trunc('day', now() at time zone 'utc')
          + ((7 - ((extract(isodow from now() at time zone 'utc'))::int - 1)) * interval '1 day')
          - (now() at time zone 'utc')))::bigint;

  with ranked as (
    select r.player_id, p.name, r.score,
           row_number() over (order by r.score desc, r.updated_at asc) as rank
    from public.tv_records r
    join public.tv_players p on p.player_id = r.player_id
    where r.game = p_game and r.week = w and r.score > 0 and not p.banned
  )
  select jsonb_build_object(
    'secs_left', secs,
    'top', coalesce((
      select jsonb_agg(jsonb_build_object(
               'rank', k.rank, 'name', k.name, 'score', k.score,
               'best', coalesce((select score from public.tv_records a where a.player_id = k.player_id and a.game = p_game and a.week = 0), k.score),
               'me', k.player_id = p_player_id) order by k.rank)
      from ranked k where k.rank <= p_limit), '[]'::jsonb),
    'me', (
      select jsonb_build_object('rank', k.rank, 'score', k.score,
               'best', coalesce((select score from public.tv_records a where a.player_id = k.player_id and a.game = p_game and a.week = 0), k.score))
      from ranked k where k.player_id = p_player_id)
  ) into res;
  return res;
end $$;

-- ---------- Admin ----------
create or replace function public.tv_set_admin_pass(p_pass text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_pass is null or length(p_pass) < 8 then raise exception 'Şifre en az 8 karakter olmalı'; end if;
  insert into public.tv_admin (id, hash, fails, locked_until) values (1, crypt(p_pass, gen_salt('bf')), 0, null)
  on conflict (id) do update set hash = excluded.hash, fails = 0, locked_until = null;
end $$;

create or replace function public.tv_admin(p_pass text, p_action text, p_args jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare a public.tv_admin%rowtype; res jsonb; w integer := public.tv_week();
        q text; lim integer; ofs integer; gm text; md text; pid text; nn text;
begin
  select * into a from public.tv_admin where id = 1;
  if not found or a.hash is null then return jsonb_build_object('ok', false, 'err', 'nopass'); end if;
  if a.locked_until is not null and a.locked_until > now() then
    return jsonb_build_object('ok', false, 'err', 'locked');
  end if;
  if crypt(coalesce(p_pass, ''), a.hash) <> a.hash then
    update public.tv_admin
       set locked_until = case when fails + 1 >= 8 then now() + interval '15 minutes' else null end,
           fails = case when fails + 1 >= 8 then 0 else fails + 1 end
     where id = 1;
    perform pg_sleep(1);
    return jsonb_build_object('ok', false, 'err', 'auth');
  end if;
  update public.tv_admin set fails = 0, locked_until = null where id = 1;

  if p_action = 'ping' then
    return jsonb_build_object('ok', true);

  elsif p_action = 'stats' then
    return jsonb_build_object('ok', true, 'week', w,
      'players', (select count(*) from public.tv_players),
      'banned', (select count(*) from public.tv_players where banned),
      'new_24h', (select count(*) from public.tv_players where created_at > now() - interval '1 day'),
      'new_7d', (select count(*) from public.tv_players where created_at > now() - interval '7 days'),
      'active_24h', (select count(*) from public.tv_players where last_seen > now() - interval '1 day'),
      'active_7d', (select count(*) from public.tv_players where last_seen > now() - interval '7 days'),
      'active_30d', (select count(*) from public.tv_players where last_seen > now() - interval '30 days'),
      'week_players', (select count(distinct player_id) from public.tv_records where week = w),
      'records', (select count(*) from public.tv_records),
      'platforms', coalesce((select jsonb_object_agg(k, c) from (select coalesce(device->>'platform', '?') k, count(*) c from public.tv_players group by 1) t), '{}'::jsonb),
      'langs', coalesce((select jsonb_object_agg(k, c) from (select coalesce(device->>'lang', '?') k, count(*) c from public.tv_players group by 1) t), '{}'::jsonb),
      'versions', coalesce((select jsonb_object_agg(k, c) from (select coalesce(device->>'build', '?') k, count(*) c from public.tv_players group by 1) t), '{}'::jsonb),
      'games', coalesce((select jsonb_agg(jsonb_build_object('game', game, 'players', c, 'week_players', wc) order by c desc)
                from (select game, count(*) filter (where week = 0) c, count(*) filter (where week = w) wc
                      from public.tv_records group by game) t), '[]'::jsonb));

  elsif p_action = 'players' then
    q := lower(coalesce(p_args->>'q', ''));
    lim := least(greatest(coalesce((p_args->>'limit')::int, 50), 1), 200);
    ofs := greatest(coalesce((p_args->>'offset')::int, 0), 0);
    select jsonb_build_object('ok', true,
      'total', (select count(*) from public.tv_players where q = '' or lower(name) like '%' || q || '%' or lower(player_id) like q || '%'),
      'rows', coalesce(jsonb_agg(to_jsonb(t) order by t.last_seen desc), '[]'::jsonb))
    into res
    from (select p.player_id, p.name, p.device, p.banned, p.created_at, p.last_seen,
                 (select count(distinct game) from public.tv_records r where r.player_id = p.player_id) as games
          from public.tv_players p
          where q = '' or lower(p.name) like '%' || q || '%' or lower(p.player_id) like q || '%'
          order by p.last_seen desc limit lim offset ofs) t;
    return res;

  elsif p_action = 'player' then
    pid := p_args->>'id';
    return jsonb_build_object('ok', true,
      'player', (select to_jsonb(p) from public.tv_players p where p.player_id = pid),
      'records', coalesce((select jsonb_agg(jsonb_build_object('game', game, 'week', week, 'score', score, 'updated_at', updated_at) order by game, week desc)
                           from public.tv_records where player_id = pid), '[]'::jsonb));

  elsif p_action = 'top' then
    gm := p_args->>'game'; md := coalesce(p_args->>'mode', 'week');
    lim := least(greatest(coalesce((p_args->>'limit')::int, 50), 1), 200);
    return jsonb_build_object('ok', true, 'rows', coalesce((
      select jsonb_agg(jsonb_build_object('rank', rank, 'player_id', player_id, 'name', name, 'score', score, 'banned', banned) order by rank)
      from (select r.player_id, p.name, p.banned, r.score,
                   row_number() over (order by r.score desc, r.updated_at asc) as rank
            from public.tv_records r join public.tv_players p on p.player_id = r.player_id
            where r.game = gm and r.week = case when md = 'all' then 0 else w end and r.score > 0) t
      where rank <= lim), '[]'::jsonb));

  elsif p_action = 'rename' then
    pid := p_args->>'id'; nn := btrim(coalesce(p_args->>'name', ''));
    if char_length(nn) < 2 or char_length(nn) > 20 then return jsonb_build_object('ok', false, 'err', 'invalid'); end if;
    begin
      update public.tv_players set name = nn where player_id = pid;
    exception when unique_violation then
      return jsonb_build_object('ok', false, 'err', 'taken');
    end;
    return jsonb_build_object('ok', true);

  elsif p_action = 'ban' then
    update public.tv_players set banned = coalesce((p_args->>'banned')::boolean, true) where player_id = p_args->>'id';
    return jsonb_build_object('ok', true);

  elsif p_action = 'delete_player' then
    delete from public.tv_players where player_id = p_args->>'id';
    return jsonb_build_object('ok', true);

  elsif p_action = 'delete_record' then
    delete from public.tv_records
     where player_id = p_args->>'id' and game = p_args->>'game'
       and (p_args->>'week' is null or week = (p_args->>'week')::int);
    return jsonb_build_object('ok', true);
  end if;

  return jsonb_build_object('ok', false, 'err', 'action');
end $$;

-- ---------- Yetkiler ----------
revoke all on function public.tv_week() from public;
revoke all on function public.tv_clean_name(text) from public;
revoke all on function public.tv_register(text, text, jsonb) from public;
revoke all on function public.tv_submit(text, text, integer, integer) from public;
revoke all on function public.tv_top(text, text, text, integer) from public;
revoke all on function public.tv_set_admin_pass(text) from public;
revoke all on function public.tv_admin(text, text, jsonb) from public;

grant execute on function public.tv_register(text, text, jsonb) to anon, authenticated;
grant execute on function public.tv_submit(text, text, integer, integer) to anon, authenticated;
grant execute on function public.tv_top(text, text, text, integer) to anon, authenticated;
grant execute on function public.tv_admin(text, text, jsonb) to anon, authenticated;
-- tv_set_admin_pass: kimseye açık değil, sadece SQL Editor'den (postgres) çalışır.

notify pgrst, 'reload schema';

-- ============ SON ADIM: admin şifreni belirle ============
-- Aşağıdaki satırdaki SIFREYI_DEGISTIR yerine kendi şifreni yaz (en az 8 karakter), sonra çalıştır.
-- Şifre sadece sunucuda şifrelenmiş saklanır, uygulamada veya GitHub'da yazmaz.
-- select public.tv_set_admin_pass('SIFREYI_DEGISTIR');
