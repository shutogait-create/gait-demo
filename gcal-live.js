/* =========================================================
 * Googleカレンダー即時連動（予約ページ・会員アプリ共通）
 * - 空き枠を出すとき、Googleカレンダーの「埋まっている時間」をその場で取りにいく
 * - 予約を確定する直前にもう一度確認して、ダブルブッキングを防ぐ
 * 予定名はお客様側に一切送られません（時間だけ）。
 * GCAL_URL は「gait 会計連携（予約アプリ）」のウェブアプリURL（/exec で終わるもの）
 * ========================================================= */
const GCAL_URL = "";
const GCAL_TIMEOUT = 7000;

function gcalEnabled(){ return /^https:\/\/script\.google\.com\//.test(GCAL_URL); }

// [{s,e}]（ミリ秒）を返す。取れなかったときは null
async function gcalBusy(fromIso, toIso){
  if(!gcalEnabled()) return [];
  const ctl = ("AbortController" in window) ? new AbortController() : null;
  const tm = ctl ? setTimeout(()=>ctl.abort(), GCAL_TIMEOUT) : null;
  try{
    const u = GCAL_URL + "?action=busy&from=" + encodeURIComponent(fromIso) + "&to=" + encodeURIComponent(toIso) + "&_=" + Date.now();
    const r = await fetch(u, { method:"GET", redirect:"follow", signal: ctl ? ctl.signal : undefined });
    const j = await r.json();
    if(!j || !j.ok) return null;
    return (j.busy||[]).map(x => ({ s: +new Date(x.s), e: +new Date(x.e) }));
  }catch(e){
    return null;
  }finally{
    if(tm) clearTimeout(tm);
  }
}

// その日（JST）のカレンダー上の埋まり。前後のあき時間（buf 分）を足して返す
async function gcalBusyDay(ds, bufMin){
  const iv = await gcalBusy(ds + "T00:00:00+09:00", ds + "T23:59:59+09:00");
  if(!iv) return null;
  const B = (bufMin||0) * 60000;
  return iv.map(x => ({ s: x.s - B, e: x.e + B }));
}

// 確定直前のチェック：この時間がカレンダーで埋まっていたら true
// 取れなかったとき（通信エラー）は false を返して予約は通す（15分ごとの同期が後で拾う）
async function gcalTaken(startMs, endMs, bufMin){
  if(!gcalEnabled()) return false;
  const B = (bufMin||0) * 60000;
  const iv = await gcalBusy(new Date(startMs - B - 60000).toISOString(), new Date(endMs + B + 60000).toISOString());
  if(!iv) return false;
  return iv.some(x => startMs < x.e + B && endMs > x.s - B);
}
