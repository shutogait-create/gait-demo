-- ============================================================
-- 新規予約メールに「電話番号」と「年齢（生年月日）」を載せるための関数
--  呼び出し元: Apps Script「gait カレンダー連携」の doPost（新規予約メールを送る直前）
--  探し方: ①会員予約 → その会員の生年月日
--          ②登録なし予約 → 同じ電話番号の顧客の生年月日（サロンボードから取り込んだ分を含む）
--          どちらも無ければ age = null（メールには「未登録」と出る）
--  合言葉: private.app_settings の hook_secret（Apps Script の SHARED_SECRET と同じ値）
--  使い方: Supabase → SQL Editor に全文を貼り、<SECRET> を合言葉に差し替えて Run
-- ============================================================
create schema if not exists private;
create table if not exists private.app_settings (key text primary key, value text not null, note text);

insert into private.app_settings(key, value, note) values
  ('hook_secret', '<SECRET>', 'Apps Script「gait カレンダー連携」の SHARED_SECRET')
on conflict (key) do update set value = excluded.value;

create or replace function public.booking_customer_age(p_secret text, p_booking_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_secret text; v_dob date; v_member uuid; v_tel text; v_ptel text;
begin
  select value into v_secret from private.app_settings where key = 'hook_secret';
  if coalesce(v_secret,'') = '' or p_secret is distinct from v_secret then
    return jsonb_build_object('ok', false);
  end if;

  select b.member_id, regexp_replace(coalesce(b.guest_tel,''), '\D', '', 'g')
    into v_member, v_tel
    from public.bookings b where b.id = p_booking_id;

  if v_member is not null then
    begin select p.dob::date into v_dob from public.profiles p where p.id = v_member; exception when others then v_dob := null; end;
  end if;
  if v_member is not null then
    begin select regexp_replace(coalesce(p.tel,''), '\D', '', 'g') into v_ptel from public.profiles p where p.id = v_member; exception when others then v_ptel := null; end;
    if coalesce(v_tel,'') = '' then v_tel := coalesce(v_ptel,''); end if;
  end if;

  if v_dob is null and coalesce(v_tel,'') <> '' then
    begin
      select p.dob::date into v_dob
        from public.profiles p
       where regexp_replace(coalesce(p.tel,''), '\D', '', 'g') = v_tel
         and p.dob is not null
       order by p.created_at desc nulls last
       limit 1;
    exception when others then v_dob := null; end;
  end if;

  if v_dob is null then
    return jsonb_build_object('ok', true, 'age', null, 'dob', null, 'tel', nullif(v_tel,''));
  end if;
  return jsonb_build_object('ok', true,
    'age', extract(year from age((now() at time zone 'Asia/Tokyo')::date, v_dob))::int,
    'dob', to_char(v_dob, 'YYYY/MM/DD'),
    'tel', nullif(v_tel,''));
end $$;

revoke all on function public.booking_customer_age(text, bigint) from public;
grant execute on function public.booking_customer_age(text, bigint) to anon, authenticated;
