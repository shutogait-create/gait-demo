-- 予約の通知メールは既存の仕組み（Googleカレンダー登録つき）に任せ、こちらの予約トリガーだけ外す。
-- 新規登録（profiles）の通知は残す。
drop trigger if exists trg_notify_owner_mail on public.bookings;
