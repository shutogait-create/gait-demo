-- ============================================================
-- 段階B：お客さま本人への LINE 通知（予約確認／キャンセル／日時変更／前日リマインド）
--  前提: supabase/line_notify.sql（段階A）を先に実行済み
--        private.app_settings に line_channel_token が入っている
--  仕組み:
--    1. profiles.line_user_id にお客さまの LINE userId を保存
--       （book.html を LIFF で開いた時に取得 → 予約成功後に link_line() で紐付け）
--    2. bookings の INSERT / status / starts_at 変更 → お客さまへ push
--    3. pg_cron 毎日 18:00 JST → 翌日の予約に前日リマインド push
--  ※ LINE userId が無いお客さま（LIFF 経由でない予約）には何も送らない
-- ============================================================

create extension if not exists pg_cron;

-- 1) LINE userId の保存先
alter table public.profiles add column if not exists line_user_id text;
create index if not exists profiles_line_user_id_idx on public.profiles(line_user_id);

-- 2) 共通 push 関数（段階Aと同じ token を使う）
create or replace function private.line_push(p_uid text, p_text text)
returns void
language plpgsql
security definer
set search_path = public, private, net
as $$
declare v_token text;
begin
  if coalesce(p_uid,'') = '' then return; end if;
  select value into v_token from private.app_settings where key = 'line_channel_token';
  if coalesce(v_token,'') = '' then return; end if;
  perform net.http_post(
    url     := 'https://api.line.me/v2/bot/message/push',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'Authorization','Bearer ' || v_token),
    body    := jsonb_build_object('to', p_uid,
                 'messages', jsonb_build_array(jsonb_build_object('type','text','text', p_text))));
exception when others then
  return;
end;
$$;

-- 3) 予約1件を「MM/DD(曜) HH:MI」＋メニュー＋担当 の文字列にする
create or replace function private.booking_line(p_booking_id uuid)
returns text
language sql
stable
set search_path = public
as $$
  select to_char(b.starts_at at time zone 'Asia/Tokyo', 'MM/DD')
      || '(' || (array['日','月','火','水','木','金','土'])[extract(dow from b.starts_at at time zone 'Asia/Tokyo')::int + 1] || ') '
      || to_char(b.starts_at at time zone 'Asia/Tokyo', 'HH24:MI') || '〜'
      || chr(10) || coalesce(m.name,'')
      || chr(10) || '担当：' || coalesce(s.name,'')
  from public.bookings b
  left join public.menus m on m.id = b.menu_id
  left join public.staff s on s.id = b.staff_id
  where b.id = p_booking_id;
$$;

-- 4) お客さまへの通知（新規／キャンセル／日時変更）
create or replace function private.line_notify_customer()
returns trigger
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_uid  text;
  v_msg  text;
  v_foot text := chr(10) || chr(10) || '▶ ご予約の確認・変更・キャンセル' || chr(10) || 'https://app.gait-pilates.com/me.html';
begin
  select line_user_id into v_uid from public.profiles where id = new.member_id;
  if coalesce(v_uid,'') = '' then return new; end if;

  if tg_op = 'INSERT' and new.status = 'confirmed' then
    v_msg := 'ご予約を承りました🌿' || chr(10) || chr(10)
          || private.booking_line(new.id) || chr(10) || chr(10)
          || '前日18時にリマインドをお送りします。' || v_foot;
  elsif tg_op = 'UPDATE' and new.status = 'cancelled' and coalesce(old.status,'') <> 'cancelled' then
    v_msg := 'ご予約をキャンセルしました。' || chr(10) || chr(10)
          || private.booking_line(new.id) || chr(10) || chr(10)
          || 'またのご利用をお待ちしています。' || v_foot;
  elsif tg_op = 'UPDATE' and new.starts_at <> old.starts_at then
    v_msg := 'ご予約の日時を変更しました。' || chr(10) || chr(10)
          || private.booking_line(new.id) || v_foot;
  else
    return new;
  end if;

  perform private.line_push(v_uid, v_msg);
  return new;
exception when others then
  return new;
end;
$$;

drop trigger if exists trg_line_notify_customer on public.bookings;
create trigger trg_line_notify_customer
  after insert or update of status, starts_at on public.bookings
  for each row execute function private.line_notify_customer();

-- 5) 予約成功後に book.html から呼ぶ：電話番号＋お名前で本人を特定し LINE userId を紐付け
--    初回（まだ userId が無かった人）は、直前の予約の確認通知もここで送る
create or replace function public.link_line(p_tel text, p_name text, p_line_uid text)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_tel  text := regexp_replace(coalesce(p_tel,''), '\D', '', 'g');
  v_pid  uuid;
  v_was  text;
  v_bid  uuid;
begin
  if length(v_tel) < 10 or coalesce(p_line_uid,'') !~ '^U[0-9a-f]{32}$' then
    return jsonb_build_object('ok', false, 'reason', 'bad_input');
  end if;

  select id, line_user_id into v_pid, v_was
  from public.profiles
  where regexp_replace(coalesce(tel,''), '\D', '', 'g') = v_tel
    and (full_name = p_name or nickname = p_name)
  order by created_at desc
  limit 1;
  if v_pid is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  update public.profiles set line_user_id = p_line_uid where id = v_pid;

  -- 初回紐付け：INSERT トリガ時点では userId が無く通知できていないので、ここで送る
  if coalesce(v_was,'') = '' then
    select id into v_bid from public.bookings
    where member_id = v_pid and status = 'confirmed'
      and created_at > now() - interval '3 minutes'
    order by created_at desc limit 1;
    if v_bid is not null then
      perform private.line_push(p_line_uid,
        'ご予約を承りました🌿' || chr(10) || chr(10) || private.booking_line(v_bid) || chr(10) || chr(10)
        || '前日18時にリマインドをお送りします。' || chr(10) || chr(10)
        || '▶ ご予約の確認・変更・キャンセル' || chr(10) || 'https://app.gait-pilates.com/me.html');
    end if;
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.link_line(text, text, text) to anon, authenticated;

-- 6) 前日リマインド（毎日 18:00 JST = 09:00 UTC）
create or replace function private.line_remind_tomorrow()
returns integer
language plpgsql
security definer
set search_path = public, private
as $$
declare
  r record;
  n integer := 0;
  v_tomorrow date := (now() at time zone 'Asia/Tokyo')::date + 1;
begin
  for r in
    select b.id, p.line_user_id
    from public.bookings b
    join public.profiles p on p.id = b.member_id
    where b.status = 'confirmed'
      and coalesce(p.line_user_id,'') <> ''
      and (b.starts_at at time zone 'Asia/Tokyo')::date = v_tomorrow
  loop
    perform private.line_push(r.line_user_id,
      '明日のご予約のご案内です🌿' || chr(10) || chr(10) || private.booking_line(r.id) || chr(10) || chr(10)
      || 'お気をつけてお越しください。' || chr(10)
      || '変更・キャンセルは前日までにお願いします。' || chr(10) || chr(10)
      || '▶ 確認・変更・キャンセル' || chr(10) || 'https://app.gait-pilates.com/me.html');
    n := n + 1;
  end loop;
  return n;
end;
$$;

select cron.unschedule('line_remind_tomorrow') where exists (select 1 from cron.job where jobname = 'line_remind_tomorrow');
select cron.schedule('line_remind_tomorrow', '0 9 * * *', $$select private.line_remind_tomorrow();$$);

-- 動作確認（自分の LINE userId を自分のプロフィールに入れてから予約テスト）:
--   update public.profiles set line_user_id = 'Uxxxxxxxx' where tel = '090xxxxxxxx';
--   select private.line_remind_tomorrow();   -- 翌日予約があれば即時にリマインドが届く
