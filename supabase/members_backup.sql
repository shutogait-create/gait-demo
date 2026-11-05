-- ============================================================
-- 会員の利用記録・会員一覧・毎晩のバックアップ用（2026-11-05）
-- Supabase の SQL エディタに貼って「Run」（オーナー本人が実行）
-- 何度実行しても壊れないように書いています
-- ============================================================

-- オーナーかどうか（以下の関数で使う）
create or replace function public.gait_is_owner()
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.profiles where id = auth.uid() and role = 'owner');
$$;
revoke all on function public.gait_is_owner() from public, anon;
grant execute on function public.gait_is_owner() to authenticated;

-- ① 会員アプリの利用記録（どのページを開いたか）
create table if not exists public.app_events (
  id         bigserial primary key,
  member_id  uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  page       text not null check (char_length(page) <= 40),
  detail     text check (detail is null or char_length(detail) <= 120),
  at         timestamptz not null default now()
);
create index if not exists app_events_member_at on public.app_events(member_id, at desc);
create index if not exists app_events_at on public.app_events(at desc);
alter table public.app_events enable row level security;
drop policy if exists app_events_insert_own on public.app_events;
create policy app_events_insert_own on public.app_events
  for insert to authenticated with check (member_id = auth.uid());
drop policy if exists app_events_owner_read on public.app_events;
create policy app_events_owner_read on public.app_events
  for select to authenticated using (public.gait_is_owner());
-- 会員本人は自分の記録も読めない・消せない（書くだけ）

-- ② 会員登録している人の一覧（オーナーだけ）
create or replace function public.owner_member_list()
returns table(id uuid, nickname text, full_name text, tel text, email text,
              registered_at timestamptz, last_sign_in_at timestamptz,
              views_30d int, last_view_at timestamptz, top_page text)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.gait_is_owner() then raise exception 'owner only'; end if;
  return query
  select p.id, p.nickname::text, p.full_name::text, p.tel::text, u.email::text,
         u.created_at, u.last_sign_in_at,
         (select count(*) from public.app_events e where e.member_id = p.id and e.at > now() - interval '30 days')::int,
         (select max(e.at) from public.app_events e where e.member_id = p.id),
         (select e.page from public.app_events e where e.member_id = p.id and e.at > now() - interval '30 days'
            group by e.page order by count(*) desc limit 1)::text
  from public.profiles p
  join auth.users u on u.id = p.id
  where p.role is distinct from 'owner'
  order by u.last_sign_in_at desc nulls last;
end $$;
revoke all on function public.owner_member_list() from public, anon;
grant execute on function public.owner_member_list() to authenticated;

-- ③ ページごとの閲覧数（オーナーだけ）
create or replace function public.owner_page_stats(p_days int default 30)
returns table(page text, views int, people int, last_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.gait_is_owner() then raise exception 'owner only'; end if;
  return query
  select e.page, count(*)::int, count(distinct e.member_id)::int, max(e.at)
  from public.app_events e
  where e.at > now() - make_interval(days => greatest(1, least(p_days, 365)))
  group by e.page order by 2 desc;
end $$;
revoke all on function public.owner_page_stats(int) from public, anon;
grant execute on function public.owner_page_stats(int) to authenticated;

-- ④ 毎晩のバックアップ用：合言葉を知っている Apps Script だけが全データを読み出せる
create table if not exists public.backup_secret (
  id int primary key default 1 check (id = 1),
  secret text not null,
  updated_at timestamptz not null default now()
);
alter table public.backup_secret enable row level security;
-- ポリシーを作らない＝アプリからは誰も読めない（関数の中だけで照合）

-- 合言葉の登録（秘書が用意した値に置き換えて実行。リポジトリには本物を書かない）
insert into public.backup_secret(id, secret) values (1, '__BACKUP_SECRET__')
  on conflict (id) do update set secret = excluded.secret, updated_at = now();

create or replace function public.export_backup(p_secret text)
returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare
  tbls text[] := array['profiles','bookings','menus','staff','tickets','ticket_uses','payments','categories',
                       'assessments','problems','pain_logs','soap_notes','progress_photos','video_assignments','videos',
                       'waitlist','staff_day_overrides','gcal_inbox','mail_list','app_events'];
  t text; out jsonb := '{}'::jsonb; part jsonb;
begin
  if p_secret is null or length(p_secret) < 32
     or not exists(select 1 from public.backup_secret where id = 1 and secret = p_secret) then
    raise exception 'denied';
  end if;
  foreach t in array tbls loop
    if to_regclass('public.' || t) is not null then
      execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from public.%I x', t) into part;
      out := out || jsonb_build_object(t, part);
    end if;
  end loop;
  -- 会員登録（メール・登録日・最終ログイン）
  out := out || jsonb_build_object('members', (
    select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'email', u.email, 'registered_at', u.created_at,
                                                 'last_sign_in_at', u.last_sign_in_at)), '[]'::jsonb)
    from auth.users u));
  out := out || jsonb_build_object('exported_at', now());
  return out;
end $$;
revoke all on function public.export_backup(text) from public;
grant execute on function public.export_backup(text) to anon, authenticated;
