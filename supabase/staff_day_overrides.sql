-- ============================================================
-- 日付ごとのお休み・臨時出勤（2026-11-02）
--  ・表 staff_day_overrides はオーナーだけが読み書きできる（メモ＝お休みの理由はお客様に見せない）
--  ・予約画面は関数 day_overrides() で「日付・担当・休み/出勤・時間」だけを受け取る
--  ・予約の確定時にも staff_available() で日付の設定を確認する（画面を細工されても休みの日に予約できない）
-- ============================================================
create table if not exists public.staff_day_overrides (
  id bigserial primary key,
  staff_id bigint not null references public.staff(id) on delete cascade,
  d date not null,
  kind text not null check (kind in ('off','on')),
  work_from time,
  work_to time,
  note text,
  created_at timestamptz not null default now(),
  unique (staff_id, d)
);
alter table public.staff_day_overrides enable row level security;
drop policy if exists sdo_owner_all on public.staff_day_overrides;
create policy sdo_owner_all on public.staff_day_overrides for all using (public.is_owner()) with check (public.is_owner());

create or replace function public.day_overrides(p_from date, p_to date)
returns table(staff_id bigint, d date, kind text, work_from time, work_to time)
language sql stable security definer set search_path = public
as $$
  select o.staff_id, o.d, o.kind, o.work_from, o.work_to
  from public.staff_day_overrides o
  where o.d between p_from and least(p_to, p_from + 120)
$$;
grant execute on function public.day_overrides(date, date) to anon, authenticated;

create or replace function public.staff_available(p_staff_id bigint, p_starts_at timestamp with time zone)
returns boolean
language sql stable security definer set search_path = public
as $$
  select case
    when exists (select 1 from staff_day_overrides o
                 where o.staff_id = p_staff_id and o.d = (p_starts_at at time zone 'Asia/Tokyo')::date and o.kind = 'off') then false
    when exists (select 1 from staff_day_overrides o
                 where o.staff_id = p_staff_id and o.d = (p_starts_at at time zone 'Asia/Tokyo')::date and o.kind = 'on') then true
    else exists (
      select 1 from staff s
      where s.id = p_staff_id
        and (extract(dow from (p_starts_at at time zone 'Asia/Tokyo'))::int)::text = any(string_to_array(coalesce(s.work_days,''), ','))
        and ( not s.skip_holidays or not exists (select 1 from holidays h where h.d = (p_starts_at at time zone 'Asia/Tokyo')::date) ))
  end
$$;
