-- ============================================================
-- 予約（新規・キャンセル・日時変更）と新規登録を、オーナーのGmailに通知する
--  仕組み: bookings / profiles にINSERT・UPDATE → トリガ → pg_net で
--          「gait 会計連携（予約アプリ）」のウェブアプリ(action=notify) を呼ぶ → MailApp で自分宛にメール
--  Googleカレンダー同期(source=gcal)と私用ブロック(block)は通知しない
--  使い方: Supabase → SQL Editor に全文を貼って Run（<URL> と <TOKEN> は差し替え済みのものを使う）
-- ============================================================
create extension if not exists pg_net;
create schema if not exists private;
create table if not exists private.app_settings (key text primary key, value text not null, note text);

insert into private.app_settings(key, value, note) values
  ('kaikei_url',   '<URL>',   '予約アプリ会計連携（Apps Script ウェブアプリ）のURL'),
  ('kaikei_token', '<TOKEN>', 'アプリ連携シートの合言葉')
on conflict (key) do update set value = excluded.value;

create or replace function private.notify_owner_mail()
returns trigger
language plpgsql
security definer
set search_path = public, private, net
as $$
declare
  v_url text; v_tok text; v_kind text; v_name text; v_tel text; v_menu text; v_staff text; v_body jsonb;
begin
  select value into v_url from private.app_settings where key = 'kaikei_url';
  select value into v_tok from private.app_settings where key = 'kaikei_token';
  if coalesce(v_url,'') = '' then return new; end if;

  if tg_table_name = 'profiles' then
    v_body := jsonb_build_object('action','notify','token',v_tok,'kind','新規登録',
      'name', coalesce(nullif(new.full_name,''), nullif(new.nickname,''), '（名前なし）'),
      'tel', coalesce(new.tel,''),
      'created_at', to_char(coalesce(new.created_at, now()) at time zone 'Asia/Tokyo', 'YYYY/MM/DD HH24:MI'));
  else
    if coalesce(new.source,'') in ('gcal','block') then return new; end if;
    if tg_op = 'INSERT' then v_kind := '新規予約';
    elsif tg_op = 'UPDATE' and new.status = 'cancelled' and coalesce(old.status,'') <> 'cancelled' then v_kind := 'キャンセル';
    elsif tg_op = 'UPDATE' and new.starts_at <> old.starts_at then v_kind := '日時変更';
    else return new; end if;
    select name into v_menu  from public.menus where id = new.menu_id;
    select name into v_staff from public.staff where id = new.staff_id;
    select coalesce(nullif(full_name,''), nullif(nickname,'')), tel into v_name, v_tel from public.profiles where id = new.member_id;
    v_name := coalesce(v_name, new.guest_name, new.title, '（名前なし）');
    v_tel  := coalesce(nullif(v_tel,''), new.guest_tel, '');
    v_body := jsonb_build_object('action','notify','token',v_tok,'kind',v_kind,
      'name', v_name, 'tel', v_tel, 'menu', coalesce(v_menu, new.title, ''), 'staff', coalesce(v_staff,''),
      'when', to_char(new.starts_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'channel', coalesce(new.channel,''), 'note', coalesce(new.customer_note,''), 'booking_id', new.id);
  end if;

  perform net.http_post(url := v_url, body := v_body, headers := '{"Content-Type":"application/json"}'::jsonb);
  return new;
exception when others then
  return new;   -- 通知に失敗しても予約自体は通す
end $$;

drop trigger if exists trg_notify_owner_mail on public.bookings;
create trigger trg_notify_owner_mail
  after insert or update on public.bookings
  for each row execute function private.notify_owner_mail();

drop trigger if exists trg_notify_owner_mail_profile on public.profiles;
create trigger trg_notify_owner_mail_profile
  after insert on public.profiles
  for each row execute function private.notify_owner_mail();
