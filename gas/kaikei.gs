/**
 * gait 会計連携（スプレッドシート「gait」の Apps Script に貼り付けて使う）
 *
 * できること
 *  - 予約アプリの「🧾 会計」タブから送った売上・経費を「令和N年 売り上げ」シートに1行追加
 *  - 「固定費」シートに書いた家賃などを、毎月の計上日に自動で追加（二重登録しない）
 *  - 今日の売上・今月の収入/支出/経費/利益を予約アプリに返す
 *
 * 初回だけ：関数「setup」を実行 →「アプリ連携」シートに合言葉が出る → デプロイ（ウェブアプリ）
 * 合言葉はこのファイルには書かない（GitHub が公開のため）。スクリプトのプロパティに保存される。
 */

const TZ = 'Asia/Tokyo';
const EXPENSE_CATS = ['水道光熱費','旅費交通費','通信費','広告宣伝費','接待交際費','損害保険料','修繕費','消耗品','外注工賃','雑費','地代家賃','租税公課'];
const PAY_METHODS = ['現金','クレカ','PayPay','銀行振込','paypay送金'];

/* ---------- 初回セットアップ ---------- */
function setup() {
  const ss = SpreadsheetApp.getActive();
  const props = PropertiesService.getScriptProperties();
  let token = props.getProperty('TOKEN');
  if (!token) {
    token = Utilities.getUuid().replace(/-/g, '').slice(0, 20);
    props.setProperty('TOKEN', token);
  }

  // 固定費シート（無ければ作る。金額はあとで自由に書き換えてOK）
  let fx = ss.getSheetByName('固定費');
  if (!fx) {
    fx = ss.insertSheet('固定費');
    fx.getRange(1, 1, 1, 6).setValues([['有効(○)', '内容', '支払方法', '金額', '計上日(日)', 'メモ']]);
    fx.getRange(2, 1, 1, 6).setValues([['○', '家賃', '銀行振込', 187330, 27, '家賃・共益費・駐車場（1〜4月の実績額）']]);
    fx.setFrozenRows(1);
    fx.getRange('A1:F1').setFontWeight('bold').setBackground('#e6f5ee');
    fx.setColumnWidth(2, 200); fx.setColumnWidth(6, 320);
  }

  // 連携情報シート
  let ap = ss.getSheetByName('アプリ連携');
  if (!ap) ap = ss.insertSheet('アプリ連携');
  ap.getRange(1, 1, 4, 2).setValues([
    ['合言葉', token],
    ['使い方', '予約アプリ → オーナー画面 → 🧾会計 → ⚙️連携設定 に、ウェブアプリのURLとこの合言葉を1回だけ貼り付けてください'],
    ['注意', 'この合言葉は人に見せないでください（知っている人は売上シートに書き込めます）'],
    ['更新', Utilities.formatDate(new Date(), TZ, 'yyyy/MM/dd HH:mm')],
  ]);
  ap.getRange('A1:A4').setFontWeight('bold');

  // 毎朝6時に「今日が計上日の固定費」を追加するトリガー（重複作成しない）
  const has = ScriptApp.getProjectTriggers().some(t => t.getHandlerFunction() === 'postFixedCosts');
  if (!has) ScriptApp.newTrigger('postFixedCosts').timeBased().everyDays(1).atHour(6).inTimezone(TZ).create();

  return token;
}

/* ---------- 受け口 ---------- */
function doGet(e) {
  const p = (e && e.parameter) || {};
  if (!auth_(p.token)) return json_({ ok: false, error: '合言葉が違います' });
  if (p.action === 'summary') return json_(summary_());
  return json_({ ok: true, hello: 'gait 会計連携' });
}

function doPost(e) {
  let b = {};
  try { b = JSON.parse(e.postData.contents || '{}'); } catch (err) { return json_({ ok: false, error: 'データの形が不正です' }); }
  if (!auth_(b.token)) return json_({ ok: false, error: '合言葉が違います' });
  const lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    if (b.action === 'sale')    return json_(addSale_(b));
    if (b.action === 'expense') return json_(addExpense_(b));
    return json_({ ok: false, error: '不明な操作です' });
  } catch (err) {
    return json_({ ok: false, error: String(err.message || err) });
  } finally {
    lock.releaseLock();
  }
}

/* ---------- 売上（または固定費などの支出）を A〜G 列に1行追加 ---------- */
function addSale_(b) {
  const amount = Math.round(Number(b.amount));
  if (!amount || amount < 0) throw new Error('金額を入れてください');
  if (PAY_METHODS.indexOf(b.method) < 0) throw new Error('支払方法が不正です');
  const d = parseDate_(b.date) || new Date();
  const name = String(b.customer || '').trim();
  const content = String(b.content || '').trim() + (name ? '(' + name : '');   // 既存の書き方「パーソナル(伊藤」に合わせる
  const isExpense = b.kind === 'out';
  appendMainRow_(salesSheet_(d), [
    d, b.method, content, String(b.source || ''), String(b.category || (isExpense ? '支払い' : '')),
    isExpense ? 0 : amount, isExpense ? amount : 0,
  ]);
  return { ok: true, saved: { date: fmt_(d), content: content, amount: amount } };
}

/* ---------- 経費を費目ごとの4列ブロック（日付・場所・事柄・金額）に追加 ---------- */
function addExpense_(b) {
  const amount = Math.round(Number(b.amount));
  if (!amount || amount < 0) throw new Error('金額を入れてください');
  if (EXPENSE_CATS.indexOf(b.cat) < 0) throw new Error('費目が不正です');
  const d = parseDate_(b.date) || new Date();
  const sh = salesSheet_(d);
  const col = headerCol_(sh, b.cat);                 // 金額の列（1始まり）
  if (!col || col < 4) throw new Error('「' + b.cat + '」の列が見つかりません');
  const dateCol = col - 3;
  const row = firstEmptyRow_(sh, dateCol, 3);
  const above = row > 3 ? row - 1 : 3;
  sh.getRange(above, dateCol, 1, 4).copyTo(sh.getRange(row, dateCol, 1, 4), SpreadsheetApp.CopyPasteType.PASTE_FORMAT, false);
  sh.getRange(row, dateCol, 1, 4).setValues([[d, String(b.place || ''), String(b.memo || ''), amount]]);
  return { ok: true, saved: { date: fmt_(d), cat: b.cat, amount: amount } };
}

/* ---------- 固定費：毎朝のトリガーで、今日が計上日のものを追加 ---------- */
function postFixedCosts() {
  const ss = SpreadsheetApp.getActive();
  const fx = ss.getSheetByName('固定費');
  if (!fx || fx.getLastRow() < 2) return;
  const today = new Date();
  const day = Number(Utilities.formatDate(today, TZ, 'd'));
  const ym = Utilities.formatDate(today, TZ, 'yyyy-MM');
  const lastDay = new Date(today.getFullYear(), today.getMonth() + 1, 0).getDate();
  const props = PropertiesService.getScriptProperties();
  fx.getRange(2, 1, fx.getLastRow() - 1, 6).getValues().forEach((r, i) => {
    const [on, content, method, amount, postDay] = r;
    if (String(on).trim() !== '○' || !content || !amount) return;
    const target = Math.min(Number(postDay) || 1, lastDay);       // 31日指定でも月末に計上
    if (day !== target) return;
    const key = 'fixed_' + ym + '_' + (i + 2) + '_' + content;
    if (props.getProperty(key)) return;                           // 同じ月に二重計上しない
    appendMainRow_(salesSheet_(today), [today, PAY_METHODS.indexOf(method) >= 0 ? method : '銀行振込', String(content), '', '支払い', 0, Math.round(Number(amount))]);
    props.setProperty(key, '1');
  });
}

/* ---------- 今日・今月の数字 ---------- */
function summary_() {
  const now = new Date();
  const sh = salesSheet_(now);
  const todayKey = Utilities.formatDate(now, TZ, 'yyyy-MM-dd');
  const monthKey = todayKey.slice(0, 7);
  const last = sh.getLastRow();
  const out = { ok: true, today: todayKey, todaySales: 0, todayItems: [], monthIn: 0, monthOut: 0, monthExp: 0, monthExpByCat: {} };
  if (last < 3) return finish_(out);

  const main = sh.getRange(3, 1, last - 2, 7).getValues();
  main.forEach(r => {
    const k = key_(r[0]); if (!k) return;
    const inc = num_(r[5]), exp = num_(r[6]);
    if (k.slice(0, 7) === monthKey) { out.monthIn += inc; out.monthOut += exp; }
    if (k === todayKey && inc > 0) { out.todaySales += inc; out.todayItems.push({ method: r[1], content: r[2], amount: inc }); }
  });

  const width = sh.getLastColumn();
  const hdr = sh.getRange(1, 1, 1, width).getValues()[0];
  const all = sh.getRange(3, 1, last - 2, width).getValues();
  EXPENSE_CATS.forEach(cat => {
    const c = hdr.indexOf(cat); if (c < 3) return;
    let s = 0;
    all.forEach(r => { const k = key_(r[c - 3]); if (k && k.slice(0, 7) === monthKey) s += num_(r[c]); });
    if (s) out.monthExpByCat[cat] = s;
    out.monthExp += s;
  });
  return finish_(out);
}
function finish_(o) { o.monthProfit = o.monthIn - o.monthOut - o.monthExp; return o; }

/* ---------- 共通の小道具 ---------- */
function salesSheet_(d) {
  const name = '令和' + (d.getFullYear() - 2018) + '年 売り上げ';
  const sh = SpreadsheetApp.getActive().getSheetByName(name);
  if (!sh) throw new Error('シート「' + name + '」が見つかりません');
  return sh;
}
// A列の最後の行の次に、A〜G を書く。H・I 列（利益・お客様名）は上の行の数式をそのまま引き継ぐ
function appendMainRow_(sh, vals) {
  const lastA = lastFilledRow_(sh, 1, 3);
  const row = lastA + 1;
  const src = Math.max(3, lastA);
  sh.getRange(src, 1, 1, 9).copyTo(sh.getRange(row, 1, 1, 9), SpreadsheetApp.CopyPasteType.PASTE_FORMAT, false);
  sh.getRange(row, 1, 1, 7).setValues([vals]);
  ['H', 'I'].forEach((L, i) => {
    const f = sh.getRange(src, 8 + i).getFormulaR1C1();
    if (f) sh.getRange(row, 8 + i).setFormulaR1C1(f);
    else if (i === 0) sh.getRange(row, 8).setValue(num_(vals[5]) - num_(vals[6]));
  });
  return row;
}
function lastFilledRow_(sh, col, startRow) {
  const n = sh.getLastRow() - startRow + 1;
  if (n < 1) return startRow - 1;
  const v = sh.getRange(startRow, col, n, 1).getValues();
  for (let i = v.length - 1; i >= 0; i--) if (v[i][0] !== '' && v[i][0] !== null) return startRow + i;
  return startRow - 1;
}
function firstEmptyRow_(sh, col, startRow) {
  const n = Math.max(1, sh.getLastRow() - startRow + 1);
  const v = sh.getRange(startRow, col, n, 1).getValues();
  for (let i = 0; i < v.length; i++) if (v[i][0] === '' || v[i][0] === null) return startRow + i;
  return startRow + v.length;
}
function headerCol_(sh, name) {
  const hdr = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0];
  const i = hdr.indexOf(name);
  return i < 0 ? 0 : i + 1;
}
function parseDate_(s) {
  if (!s) return null;
  const m = String(s).match(/^(\d{4})[-\/](\d{1,2})[-\/](\d{1,2})/);
  return m ? new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3])) : null;
}
function key_(v) {
  if (v instanceof Date) return Utilities.formatDate(v, TZ, 'yyyy-MM-dd');
  const d = parseDate_(v);
  return d ? Utilities.formatDate(d, TZ, 'yyyy-MM-dd') : '';
}
function num_(v) {
  if (typeof v === 'number') return v;
  const n = Number(String(v || '').replace(/[¥,\s円]/g, ''));
  return isNaN(n) ? 0 : n;
}
function fmt_(d) { return Utilities.formatDate(d, TZ, 'yyyy/MM/dd'); }
function auth_(t) {
  const tok = PropertiesService.getScriptProperties().getProperty('TOKEN');
  return !!tok && t === tok;
}
function json_(o) {
  return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);
}
