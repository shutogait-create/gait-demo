-- ============================================================
-- 予約の新規/キャンセルをオーナーの LINE に通知する（Supabase 内で完結）
--  仕組み: bookings に INSERT / status 更新 → トリガ → pg_net で LINE Messaging API push
--  秘密情報は private.app_settings に保存（API からは見えないスキーマ）
-- ============================================================

create extension if not exists pg_net;
create schema if not exists private;

-- 設定テーブル（Table Editor から値を入れる。SQL に秘密を書かない）
create table if not exists private.app_settings (
  key   text primary key,
  value text not null,
  note  text
);
insert into private.app_settings(key, value, note) values
  ('line_channel_token', '', 'LINE Developers → Messaging API → チャネルアクセストークン（長期）'),
  ('line_owner_user_id', '', 'LINE Developers → チャネル基本設定 → あなたのユーザーID（U で始まる）')
on conflict (key) do nothing;

-- 通知本文を作って送る関数
create or replace function private.line_notify_booking()
returns trigger
language plpgsql
security definer
set search_path = public, private, net
as $$
declare
  v_token   text;
  v_uid     text;
  v_kind    text;
  v_menu    text;
  v_staff   text;
  v_name    text;
  v_when    text;
  v_wd      text[] := array['日','月','火','水','木','金','土'];
  v_local   timestamp;
  v_msg     text;
begin
  select value into v_token from private.app_settings where key = 'line_channel_token';
  select value into v_uid   from private.app_settings where key = 'line_owner_user_id';
  if coalesce(v_token,'') = '' or coalesce(v_uid,'') = '' then
    return new;  -- 未設定なら何もしない（予約自体は通す）
  end if;

  if tg_op = 'INSERT' then
    v_kind := '新規予約';
  elsif tg_op = 'UPDATE' and new.status = 'cancelled' and coalesce(old.status,'') <> 'cancelled' then
    v_kind := 'キャンセル';
  elsif tg_op = 'UPDATE' and new.starts_at <> old.starts_at then
    v_kind := '日時変更';
  else
    return new;
  end if;

  select name into v_menu  from public.menus   where id = new.menu_id;
  select name into v_staff from public.staff   where id = new.staff_id;
  select coalesce(nullif(full_name,''), nullif(nickname,''), '（名前なし）')
    into v_name from public.profiles where id = new.member_id;

  v_local := new.starts_at at time zone 'Asia/Tokyo';
  v_when  := to_char(v_local, 'MM/DD') || '(' || v_wd[extract(dow from v_local)::int + 1] || ') '
          || to_char(v_local, 'HH24:MI');

  v_msg := '【' || v_kind || '】' || chr(10)
        || v_when || chr(10)
        || coalesce(v_name,'') || ' さま' || chr(10)
        || coalesce(v_menu,'') || chr(10)
        || '担当：' || coalesce(v_staff,'')
        || case when coalesce(new.customer_note,'') <> '' then chr(10) || 'メモ：' || new.customer_note else '' end
        || chr(10) || '（' || coalesce(new.channel,'') || '）';

  perform net.http_post(
    url     := 'https://api.line.me/v2/bot/message/push',
    headers := jsonb_build_object(
                 'Content-Type',  'application/json',
                 'Authorization', 'Bearer ' || v_token),
    body    := jsonb_build_object(
                 'to', v_uid,
                 'messages', jsonb_build_array(jsonb_build_object('type','text','text', v_msg)))
  );
  return new;
exception when others then
  -- 通知の失敗で予約を止めない
  return new;
end;
$$;

drop trigger if exists trg_line_notify_booking on public.bookings;
create trigger trg_line_notify_booking
  after insert or update of status, starts_at on public.bookings
  for each row execute function private.line_notify_booking();
