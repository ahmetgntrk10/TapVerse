-- TapVerse skor tablosu
-- Supabase > SQL Editor'e yapıştırıp çalıştır.

create table if not exists public.tapverse_scores (
  player_id  text primary key,
  name       text not null,
  score      integer not null default 0,
  updated_at timestamptz not null default now()
);

alter table public.tapverse_scores enable row level security;

-- Herkes tabloyu okuyabilir (yazma sadece aşağıdaki fonksiyonla)
drop policy if exists "tapverse_scores_read" on public.tapverse_scores;
create policy "tapverse_scores_read" on public.tapverse_scores
  for select using (true);

-- Skor gönderme: sadece en iyi skoru saklar, abartılı değerleri reddeder
create or replace function public.submit_score(p_player_id text, p_name text, p_score integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_player_id is null or length(p_player_id) < 8 or length(p_player_id) > 64 then
    raise exception 'gecersiz oyuncu';
  end if;
  if p_score is null or p_score < 0 or p_score > 200000 then
    raise exception 'gecersiz skor';
  end if;
  p_name := left(trim(coalesce(p_name, 'Oyuncu')), 14);
  if p_name = '' then p_name := 'Oyuncu'; end if;

  insert into public.tapverse_scores (player_id, name, score)
  values (p_player_id, p_name, p_score)
  on conflict (player_id) do update
    set name = excluded.name,
        score = greatest(public.tapverse_scores.score, excluded.score),
        updated_at = now();
end;
$$;

grant execute on function public.submit_score(text, text, integer) to anon, authenticated;
grant select on public.tapverse_scores to anon, authenticated;
