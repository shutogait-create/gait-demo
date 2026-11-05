/**
 * gait 顧客データ 毎晩バックアップ（2026-11-05）
 * 予約アプリ（Supabase）の全データを読み出して、
 *  ① スプレッドシート「gait 顧客データ（バックアップ）」に表で書く（毎晩上書き・検索しやすい形）
 *  ② Driveフォルダ「gait バックアップ（毎晩のJSON）」に丸ごとJSONで保存（30日分残す）
 * 合言葉（BACKUP_SECRET）はスクリプトのプロパティに保存。リポジトリには本物を書かない。
 */
const SB_URL = 'https://pizzhyvqptkhigwwhorp.supabase.co';
const SB_KEY = 'sb_publishable_xrUSPujoggvnmDDzT6idXg_qgkcLJlg';   // 公開用キー（ページにも載っているもの）
const SS_ID = '107pGjgK1tcS6byRFX1KZeY56fnt8pr3mhHKhC7mMiRQ';
const FOLDER_ID = '1hECaW8QFiRNs161jrjLml2m4NfyFKPLP';
const KEEP_DAYS = 30;
const NOTIFY_TO = 'shutogait@gmail.com';

// 最初に1回だけ：合言葉をプロパティに入れる（秘書が値を入れて実行 → 実行後この行の値は消す）
function setupSecret() {
  const s = '__BACKUP_SECRET__';
  if (s.indexOf('__') === 0) throw new Error('合言葉が入っていません');
  PropertiesService.getScriptProperties().setProperty('BACKUP_SECRET', s);
}

// 最初に1回だけ：毎晩2時台に動くように設定
function setupTrigger() {
  ScriptApp.getProjectTriggers().forEach(t => { if (t.getHandlerFunction() === 'nightlyBackup') ScriptApp.deleteTrigger(t); });
  ScriptApp.newTrigger('nightlyBackup').timeBased().atHour(2).everyDays(1).inTimezone('Asia/Tokyo').create();
}

const SHEETS = [   // [データ名, シート名]
  ['bookings', '予約'], ['assessments', '身体評価'], ['pain_logs', '痛みの記録'], ['soap_notes', 'SOAPカルテ'],
  ['problems', '問題点とエクササイズ'], ['tickets', '回数券'], ['ticket_uses', '回数券の消化'], ['payments', '支払い'],
  ['video_assignments', '宿題動画'], ['progress_photos', '姿勢写真（記録）'], ['members', '会員登録'], ['app_events', 'アプリ利用記録'],
  ['profiles', '顧客（全項目）'], ['mail_list', 'メール配信リスト'], ['waitlist', 'キャンセル待ち'],
  ['menus', 'メニュー'], ['staff', 'スタッフ'], ['staff_day_overrides', '日付ごとのお休み'], ['categories', '売上区分'], ['videos', '動画'], ['gcal_inbox', 'カレンダー取り込み']
];

function nightlyBackup() {
  const started = new Date();
  try {
    const data = fetchAll_();
    saveJson_(data, started);
    writeSheets_(data, started);
  } catch (e) {
    MailApp.sendEmail(NOTIFY_TO, '【gait】毎晩のバックアップに失敗しました',
      '時刻：' + Utilities.formatDate(started, 'Asia/Tokyo', 'yyyy/MM/dd HH:mm') + '\n内容：' + e + '\n\n秘書に「バックアップ失敗のメールが来た」と伝えてください。');
    throw e;
  }
}

function fetchAll_() {
  const secret = PropertiesService.getScriptProperties().getProperty('BACKUP_SECRET');
  if (!secret) throw new Error('合言葉が未設定です（setupSecret を実行）');
  const res = UrlFetchApp.fetch(SB_URL + '/rest/v1/rpc/export_backup', {
    method: 'post', contentType: 'application/json', muteHttpExceptions: true,
    headers: { apikey: SB_KEY, Authorization: 'Bearer ' + SB_KEY },
    payload: JSON.stringify({ p_secret: secret })
  });
  if (res.getResponseCode() !== 200) throw new Error('読み出しエラー ' + res.getResponseCode() + '：' + res.getContentText().slice(0, 300));
  return JSON.parse(res.getContentText());
}

function saveJson_(data, now) {
  const folder = DriveApp.getFolderById(FOLDER_ID);
  const name = 'gait-backup-' + Utilities.formatDate(now, 'Asia/Tokyo', 'yyyyMMdd-HHmm') + '.json';
  folder.createFile(name, JSON.stringify(data), MimeType.PLAIN_TEXT);
  const limit = now.getTime() - KEEP_DAYS * 86400000;
  const it = folder.getFiles();
  while (it.hasNext()) { const f = it.next(); if (f.getName().indexOf('gait-backup-') === 0 && f.getDateCreated().getTime() < limit) f.setTrashed(true); }   // ゴミ箱まで（完全削除はしない）
}

function toCell_(k, v) {
  if (v === null || v === undefined) return '';
  if (v instanceof Date) return v; if (/tel|電話/.test(k) && v !== '') return "'" + v;
  if (typeof v === 'object') return JSON.stringify(v);
  if (typeof v === 'string' && /(_at|^starts_at|^ends_at)$/.test(k) && /^\d{4}-\d{2}-\d{2}T/.test(v)) { const d = new Date(v); if (!isNaN(d)) return d; }
  if (typeof v === 'string' && v.length > 45000) return v.slice(0, 45000) + '…';
  return v;
}

function writeTable_(ss, name, rows, preferred) {
  let sh = ss.getSheetByName(name) || ss.insertSheet(name);
  sh.clearContents();
  if (!rows.length) { sh.getRange(1, 1).setValue('（データなし）'); return; }
  const keys = [];
  (preferred || []).forEach(k => { if (keys.indexOf(k) < 0 && rows.some(r => k in r)) keys.push(k); });
  rows.forEach(r => Object.keys(r).forEach(k => { if (keys.indexOf(k) < 0) keys.push(k); }));
  const vals = [keys].concat(rows.map(r => keys.map(k => toCell_(k, r[k]))));
  sh.getRange(1, 1, vals.length, keys.length).setValues(vals);
  sh.setFrozenRows(1);
  sh.getRange(1, 1, 1, keys.length).setFontWeight('bold').setBackground('#e6f5ee');
  keys.forEach((k, i) => { if (/(_at|^starts_at|^ends_at)$/.test(k)) sh.getRange(2, i + 1, rows.length, 1).setNumberFormat('yyyy/mm/dd hh:mm'); });
  if (sh.getFilter()) sh.getFilter().remove();
  sh.getRange(1, 1, vals.length, keys.length).createFilter();
}

function writeSheets_(data, now) {
  const ss = SpreadsheetApp.openById(SS_ID);
  const profiles = data.profiles || [];
  const P = {}; profiles.forEach(p => P[p.id] = p);
  const nameOf = id => { const p = P[id]; return p ? (p.full_name || p.nickname || '') : ''; };
  const members = {}; (data.members || []).forEach(m => members[m.id] = m);
  const menus = {}; (data.menus || []).forEach(m => menus[m.id] = m.name);
  const nowMs = now.getTime(), today = Utilities.formatDate(now, 'Asia/Tokyo', 'yyyy-MM-dd');
  const digits = s => String(s || '').replace(/[^0-9]/g, '');

  // 名前を付けたコピー（検索しやすくする）
  const withName = rows => (rows || []).map(r => Object.assign({ 'お名前': r.member_id ? nameOf(r.member_id) : (r.guest_name || '') }, r));
  const bookings = (data.bookings || []).filter(b => b.source !== 'block')
    .map(b => Object.assign({ 'お名前': b.member_id ? nameOf(b.member_id) : (b.guest_name || b.title || ''), 'メニュー': menus[b.menu_id] || '' }, b))
    .sort((a, b) => String(b.starts_at).localeCompare(String(a.starts_at)));

  // ① 顧客一覧（1人1行）
  const telIdx = {}; profiles.forEach(p => { const t = digits(p.tel); if (t) telIdx[t] = p.id; });
  const S = {};
  const get = (key, base) => S[key] = S[key] || Object.assign({ visits: 0, last: null, first: null, next: null, cancels: 0 }, base);
  profiles.filter(p => p.role !== 'owner').forEach(p => get(p.id, { id: p.id, p: p }));
  bookings.forEach(b => {
    let key = b.member_id || (b.guest_tel && telIdx[digits(b.guest_tel)]) || null;
    if (!key) { key = 'g:' + (digits(b.guest_tel) || b.guest_name || ''); if (key === 'g:') return; get(key, { guest: true, name: b.guest_name || '', tel: b.guest_tel || '' }); }
    const s = S[key]; if (!s) return;
    const t = new Date(b.starts_at).getTime();
    if (b.status === 'cancelled') { s.cancels++; return; }
    if (t < nowMs) { s.visits++; if (!s.last || t > s.last) s.last = t; if (!s.first || t < s.first) s.first = t; }
    else if (!s.next || t < s.next) s.next = t;
  });
  const tk = {}; (data.tickets || []).forEach(t => { if (!(t.left_count > 0)) return; if (t.expires_at && String(t.expires_at).slice(0, 10) < today) return; tk[t.member_id] = (tk[t.member_id] || 0) + t.left_count; });
  const nrs = {}; (data.pain_logs || []).forEach(l => { const d = String(l.date || l.created_at || ''); if (!nrs[l.member_id] || d > nrs[l.member_id].d) nrs[l.member_id] = { d: d, v: l.nrs }; });
  const soap = {}; (data.soap_notes || []).forEach(n => { const d = String(n.date || n.created_at || ''); if (!soap[n.member_id] || d > soap[n.member_id]) soap[n.member_id] = d; });
  const pay = {}; (data.payments || []).forEach(x => { if (x.member_id) pay[x.member_id] = (pay[x.member_id] || 0) + (+x.amount || 0); });
  const ev = {}; (data.app_events || []).forEach(e => { if (nowMs - new Date(e.at).getTime() < 30 * 86400000) ev[e.member_id] = (ev[e.member_id] || 0) + 1; });
  const fmt = ms => ms ? new Date(ms) : '';
  const summary = Object.keys(S).map(k => {
    const s = S[k], p = s.p || {}, m = members[s.id] || {};
    return {
      '区分': s.guest ? '予約のみ（顧客未登録）' : (m.email ? 'アプリ登録済' : 'アプリ未登録'),
      'お名前': s.guest ? s.name : (p.full_name || p.nickname || ''), 'ニックネーム': p.nickname || '', 'カナ': p.kana || '',
      '電話': s.guest ? s.tel : (p.tel || ''), 'メール': m.email || '', '生年月日': p.dob || '',
      '来店回数': Math.max(s.visits, p.visits_offset || 0), '初回来店': fmt(s.first), '最終来店': fmt(s.last || (p.last_visit_at ? new Date(p.last_visit_at).getTime() : null)),
      '次回予約': fmt(s.next), 'キャンセル回数': s.cancels, '回数券の残り': tk[s.id] || '',
      '主訴': p.chief_complaint || '', '目標': p.goal || '', '既往歴': p.history || '', '服薬': p.medication || '',
      '最新の痛み(NRS)': nrs[s.id] ? nrs[s.id].v : '', '痛みの記録日': nrs[s.id] ? nrs[s.id].d.slice(0, 10) : '',
      '最新SOAP': soap[s.id] ? soap[s.id].slice(0, 10) : '', '支払い合計(記録分)': pay[s.id] || '',
      '会員登録日': m.registered_at ? new Date(m.registered_at) : '', '最終ログイン': m.last_sign_in_at ? new Date(m.last_sign_in_at) : '',
      'アプリ閲覧(30日)': ev[s.id] || '', 'カルテメモ': p.memo || '', '顧客ID': s.guest ? '' : s.id
    };
  }).sort((a, b) => (b['最終来店'] || 0) - (a['最終来店'] || 0));

  writeTable_(ss, '顧客一覧', summary);
  const shS = ss.getSheetByName('顧客一覧');
  if (summary.length) ['初回来店', '最終来店', '次回予約', '会員登録日', '最終ログイン'].forEach(k => {
    const i = Object.keys(summary[0]).indexOf(k); if (i >= 0) shS.getRange(2, i + 1, summary.length, 1).setNumberFormat('yyyy/mm/dd');
  });

  // ② 各データ
  SHEETS.forEach(([key, name]) => {
    let rows = data[key] || [];
    if (key === 'bookings') rows = bookings;
    else if (key === 'members') rows = rows.map(m => Object.assign({ 'お名前': nameOf(m.id) }, m));
    else if (rows.length && ('member_id' in rows[0])) rows = withName(rows);
    writeTable_(ss, name, rows, ['お名前']);
  });

  // ③ 更新情報
  const info = ss.getSheetByName('更新情報') || ss.insertSheet('更新情報', 0);
  info.clearContents();
  const lines = [['最終バックアップ', Utilities.formatDate(now, 'Asia/Tokyo', 'yyyy/MM/dd HH:mm')], ['顧客一覧', summary.length + '人']]
    .concat(SHEETS.map(([k, n]) => [n, (data[k] || []).length + '件']))
    .concat([['', ''], ['説明', '毎晩2時台に予約アプリの全データで上書きします。このシートを直接直しても予約アプリには反映されません（予約アプリの管理画面で直してください）。'],
             ['JSON', '同じ内容の丸ごとファイルを Drive「gait バックアップ（毎晩のJSON）」に' + KEEP_DAYS + '日分残しています。']]);
  info.getRange(1, 1, lines.length, 2).setValues(lines);
  info.getRange(1, 1, lines.length, 1).setFontWeight('bold');
  const s1 = ss.getSheetByName('シート1'); if (s1 && ss.getSheets().length > 1) ss.deleteSheet(s1);
}
