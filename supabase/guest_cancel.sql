-- 予約確認ページ（me.html）から、お客さま本人が予約をキャンセルできるようにする
--  本人確認：電話番号 ＋（生年月日 または お名前）。当日分はキャンセル不可（closed_old）
--  Supabase → SQL Editor に貼って Run
create or replace function public.guest_cancel(p_booking_id bigint, p_tel text, p_dob text default null, p_name text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b record; pr record;
  v_tel text := regexp_replace(coalesce(p_tel,''), '\D', '', 'g');
  v_name text := replace(replace(coalesce(p_name,''), ' ', ''), '　', '');
  tel_ok boolean := false; who_ok boolean := false;
begin
  select * into b from public.bookings where id = p_booking_id;
  if not found or coalesce(b.status,'') <> 'confirmed' then return jsonb_build_object('ok', false, 'reason', 'notfound'); end if;
  select * into pr from public.profiles where id = b.member_id;

  if v_tel = '' then return jsonb_build_object('ok', false, 'reason', 'denied'); end if;
  tel_ok := (pr.tel is not null and regexp_replace(pr.tel, '\D', '', 'g') = v_tel)
         or (b.guest_tel is not null and regexp_replace(b.guest_tel, '\D', '', 'g') = v_tel);
  if p_dob is not null and p_dob <> '' then
    begin who_ok := (pr.dob is not null and pr.dob::date = p_dob::date); exception when others then who_ok := false; end;
  end if;
  if not who_ok and v_name <> '' then
    who_ok := replace(replace(coalesce(pr.full_name,''), ' ', ''), '　', '') = v_name
           or replace(replace(coalesce(pr.nickname,''), ' ', ''), '　', '') = v_name
           or replace(replace(coalesce(b.guest_name,''), ' ', ''), '　', '') = v_name;
  end if;
  if not (tel_ok and who_ok) then return jsonb_build_object('ok', false, 'reason', 'denied'); end if;

  if b.starts_at < now() then return jsonb_build_object('ok', false, 'reason', 'notfound'); end if;
  if (b.starts_at at time zone 'Asia/Tokyo')::date <= (now() at time zone 'Asia/Tokyo')::date then
    return jsonb_build_object('ok', false, 'reason', 'closed_old');   -- 当日は電話・LINEで
  end if;

  update public.bookings
     set status = 'cancelled', cancelled_at = now(), cancel_note = 'お客さまが予約確認ページからキャンセル（前日まで・無料）'
   where id = b.id;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function public.guest_cancel(bigint, text, text, text) to anon, authenticated;
