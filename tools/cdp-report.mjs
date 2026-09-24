// 通过 Chrome DevTools Protocol 读取页面内的自检报告。
// 用途：本环境 chrome --screenshot / --virtual-time-budget 会被沙箱阻断，
// 但 CDP + Runtime.evaluate 可用，于是让页面自己采样 canvas 并回报。
const PORT = Number(process.env.CDP_PORT || 9222);

async function targets() {
  const r = await fetch(`http://127.0.0.1:${PORT}/json/list`);
  return r.json();
}

let page = null;
for (let i = 0; i < 80; i++) {
  try {
    const list = await targets();
    page = list.find((t) => t.type === 'page' && t.webSocketDebuggerUrl);
    if (page) break;
  } catch { /* chrome 还没起来 */ }
  await new Promise((r) => setTimeout(r, 500));
}
if (!page) { console.log('NO_CDP_TARGET'); process.exit(1); }

const ws = new WebSocket(page.webSocketDebuggerUrl);
let seq = 0;
const waiters = new Map();
ws.addEventListener('message', (ev) => {
  let m; try { m = JSON.parse(ev.data); } catch { return; }
  if (m.id && waiters.has(m.id)) {
    const { res, rej } = waiters.get(m.id);
    waiters.delete(m.id);
    m.error ? rej(new Error(JSON.stringify(m.error))) : res(m.result);
  }
});
const send = (method, params) =>
  new Promise((res, rej) => { const id = ++seq; waiters.set(id, { res, rej }); ws.send(JSON.stringify({ id, method, params })); });

await new Promise((r, j) => { ws.addEventListener('open', r); ws.addEventListener('error', j); });

let last = '';
for (let i = 0; i < 200; i++) {
  try {
    const r = await send('Runtime.evaluate', {
      expression: "(()=>{const e=document.getElementById('report');return e?e.textContent:'PENDING';})()",
      returnByValue: true,
    });
    const v = r && r.result && r.result.value;
    if (typeof v === 'string') {
      last = v;
      if (v.includes('LKREPORT')) { console.log(v); process.exit(0); }
    }
  } catch (e) { last = 'EVAL_ERR ' + e.message; }
  await new Promise((r) => setTimeout(r, 500));
}
console.log('TIMEOUT_NO_REPORT last=' + last.slice(0, 200));
process.exit(2);
