/// 手机遥控网页（**内置字符串，不依赖任何第三方 CDN**）。
///
/// 需求 §七.2：「手机扫码打开适配手机的网页，不要求安装伴侣 App。
/// 使用电视 App 内的本地服务和打包网页资源，**首次加载不依赖第三方 CDN**」。
///
/// 因此整页（HTML/CSS/JS）就是这一份常量，由电视端的 HttpServer 直接吐给手机；
/// 断网（没有外网）也能正常打开与操作。
///
/// ## 设计要点
/// - **声音不出电视**：页面上没有任何 `<audio>`，也不接收音频地址；
/// - 状态一律来自 WebSocket 推送的 `{type:'state'}`，页面**不保存状态副本**
///   （与电视端「单一状态源」的约定一致）；
/// - 每条命令带自增 `id`，服务端据此去重 —— 弱网重发不会连切两首；
/// - 断线自动重连（指数退避，最多 15 秒一次），重连后用 `localStorage`
///   里的凭证重新握手；凭证失效则回到配对界面；
/// - 配色沿用电视端深色玻璃体系，但按手机竖屏重排。
const String remotePageHtml = r'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#0E0E16">
<title>{{APP}} · 手机遥控</title>
<style>
  :root{
    --bg:#0E0E16; --panel:#191926; --line:#2A2A3A; --text:#fff;
    --dim:#B6B6C6; --faint:#7A7A8C; --accent:#4F8CFF; --brand:#FF3B30;
    --ok:#54D68A; --warn:#FFC24B;
  }
  *{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
  body{
    margin:0;background:linear-gradient(160deg,#171730,#0A0A12 60%);
    color:var(--text);font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",
    "PingFang SC","Microsoft YaHei",sans-serif;min-height:100vh;
    padding:env(safe-area-inset-top) 0 env(safe-area-inset-bottom);
  }
  .wrap{max-width:560px;margin:0 auto;padding:18px 16px 28px}
  h1{font-size:20px;margin:0 0 2px;letter-spacing:1px}
  .sub{color:var(--faint);font-size:13px;margin-bottom:16px}
  .card{background:var(--panel);border:1px solid var(--line);border-radius:16px;
        padding:16px;margin-bottom:14px}
  .hidden{display:none!important}
  /* 配对 */
  #pair input{width:100%;font-size:34px;letter-spacing:12px;text-align:center;
    padding:14px 8px;border-radius:12px;border:1px solid var(--line);
    background:#101018;color:#fff;text-transform:uppercase}
  button{font:inherit;color:#fff;background:#23233A;border:1px solid var(--line);
    border-radius:12px;padding:12px 16px;cursor:pointer}
  button.primary{background:var(--accent);border-color:var(--accent)}
  button:disabled{opacity:.45}
  .row{display:flex;gap:10px;align-items:center}
  .grow{flex:1}
  /* 正在播放 */
  .now{display:flex;gap:14px;align-items:center}
  .cover{width:84px;height:84px;border-radius:12px;background:#101018;
    object-fit:cover;flex:0 0 auto}
  .title{font-size:19px;font-weight:600;margin:0 0 4px;
    overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .meta{color:var(--faint);font-size:13px;
    overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .spec{color:var(--dim);font-size:12px;margin-top:4px}
  .seek{display:flex;align-items:center;gap:10px;margin-top:14px}
  input[type=range]{flex:1;accent-color:var(--accent)}
  .t{font-variant-numeric:tabular-nums;color:var(--dim);font-size:12px;min-width:42px;
     text-align:center}
  .ctrls{display:flex;justify-content:center;gap:14px;margin-top:14px}
  .ctrls button{font-size:22px;min-width:56px;padding:12px 0}
  .ctrls button.main{background:var(--accent);border-color:var(--accent);
     font-size:26px;min-width:72px}
  .tabs{display:flex;gap:8px;margin-bottom:10px}
  .tabs button{flex:1;padding:9px 0;font-size:14px}
  .tabs button.on{background:#24334F;border-color:var(--accent)}
  ul.list{list-style:none;margin:0;padding:0;max-height:46vh;overflow:auto}
  ul.list li{padding:10px 8px;border-bottom:1px solid var(--line);cursor:pointer;
    display:flex;gap:10px;align-items:center}
  ul.list li:last-child{border-bottom:none}
  ul.list li.cur{background:#24334F;border-radius:8px}
  ul.list li img{width:38px;height:38px;border-radius:7px;object-fit:cover;
    background:#101018;flex:0 0 auto}
  .li-t{font-size:15px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .li-s{font-size:12px;color:var(--faint);
    overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .status{display:flex;align-items:center;gap:8px;font-size:13px;color:var(--faint)}
  .dot{width:9px;height:9px;border-radius:50%;background:var(--warn)}
  .dot.on{background:var(--ok)}
  .search{width:100%;padding:11px 12px;border-radius:12px;border:1px solid var(--line);
    background:#101018;color:#fff;font:inherit}
  .hint{color:var(--faint);font-size:12px;margin-top:8px;line-height:1.6}
  .err{color:var(--warn);font-size:13px;margin-top:8px}
</style>
</head>
<body>
<div class="wrap">
  <h1>{{APP}}</h1>
  <div class="sub" id="sub">手机遥控 · {{HOST}}:{{PORT}}</div>

  <!-- ── 配对 ─────────────────────────────────────────── -->
  <div id="pair" class="card">
    <div style="font-size:17px;font-weight:600;margin-bottom:8px">输入电视上的配对码</div>
    <div class="hint">配对码显示在电视的「手机遥控」页面上，6 位，5 分钟内有效，且只能用一次。</div>
    <div style="height:12px"></div>
    <input id="code" inputmode="latin" autocomplete="off" maxlength="6" placeholder="······">
    <div style="height:12px"></div>
    <button class="primary grow" id="doPair" style="width:100%">配对</button>
    <div class="err hidden" id="pairErr"></div>
  </div>

  <!-- ── 遥控 ─────────────────────────────────────────── -->
  <div id="main" class="hidden">
    <div class="card">
      <div class="now">
        <img class="cover" id="cover" alt="">
        <div class="grow" style="min-width:0">
          <div class="title" id="title">未在播放</div>
          <div class="meta" id="meta"></div>
          <div class="spec" id="spec"></div>
        </div>
        <button id="fav" title="收藏">♡</button>
      </div>
      <div class="seek">
        <span class="t" id="pos">0:00</span>
        <input type="range" id="seek" min="0" max="1000" value="0">
        <span class="t" id="dur">0:00</span>
      </div>
      <div class="ctrls">
        <button id="prev">⏮</button>
        <button id="play" class="main">▶</button>
        <button id="next">⏭</button>
      </div>
      <div class="ctrls" style="margin-top:10px">
        <button id="mode" style="font-size:15px;min-width:auto">顺序</button>
        <button id="refresh" style="font-size:15px;min-width:auto">刷新</button>
      </div>
      <div class="err hidden" id="cmdErr"></div>
    </div>

    <div class="card">
      <div class="tabs">
        <button id="tabQueue" class="on">播放队列</button>
        <button id="tabBrowse">曲库</button>
      </div>
      <div id="paneQueue">
        <div class="hint" id="queueHint"></div>
        <ul class="list" id="queueList"></ul>
      </div>
      <div id="paneBrowse" class="hidden">
        <input class="search" id="q" placeholder="搜索歌曲 / 歌手 / 专辑">
        <div style="height:10px"></div>
        <div class="hint" id="browseHint"></div>
        <ul class="list" id="browseList"></ul>
      </div>
    </div>

    <div class="card">
      <div class="status"><span class="dot" id="dot"></span><span id="conn">连接中…</span></div>
      <div class="hint">声音由电视播放，手机不播放音频。断开或关闭电视端服务后需要重新配对。</div>
      <div style="height:10px"></div>
      <button id="unpair" style="width:100%">解除配对</button>
    </div>
  </div>
</div>

<script>
(function () {
  'use strict';
  var TOKEN_KEY = 'feiniu_remote_token';
  var LABEL = navigator.userAgent.indexOf('iPhone') >= 0 ? 'iPhone'
            : navigator.userAgent.indexOf('Android') >= 0 ? 'Android 手机'
            : '手机浏览器';
  var token = null;
  var ws = null;
  var seq = 0;
  var state = null;
  var queueItems = [];
  var browseOffset = 0;
  var browseItems = [];
  var modeOrder = ['sequence', 'repeat_all', 'shuffle', 'repeat_one'];
  var modeLabel = {sequence:'顺序', repeat_all:'列表循环', shuffle:'随机', repeat_one:'单曲'};
  var reconnectDelay = 1000;
  var seeking = false;

  function $(id) { return document.getElementById(id); }

  function fmt(ms) {
    if (!ms || ms < 0) ms = 0;
    var s = Math.floor(ms / 1000), m = Math.floor(s / 60);
    return m + ':' + ('0' + (s % 60)).slice(-2);
  }

  function api(path, opts) {
    opts = opts || {};
    opts.headers = Object.assign({
      'Content-Type': 'application/json',
      'x-remote-token': token || ''
    }, opts.headers || {});
    return fetch(path, opts).then(function (r) {
      if (r.status === 401) { fail('凭证已失效，请重新配对'); throw new Error('401'); }
      return r.json();
    });
  }

  function fail(msg) {
    $('pair').classList.remove('hidden');
    $('main').classList.add('hidden');
    $('pairErr').textContent = msg;
    $('pairErr').classList.remove('hidden');
    token = null;
    try { localStorage.removeItem(TOKEN_KEY); } catch (e) {}
    if (ws) { try { ws.close(); } catch (e) {} ws = null; }
    setConn(false, '未连接');
  }

  function setConn(on, text) {
    $('dot').className = 'dot' + (on ? ' on' : '');
    $('conn').textContent = text;
  }

  // ── 配对 ────────────────────────────────────────────────
  function doPair(codeArg) {
    var code = String(codeArg || $('code').value || '').trim().toUpperCase();
    if (code.length !== 6) {
      $('pairErr').textContent = '请输入 6 位配对码';
      $('pairErr').classList.remove('hidden');
      return;
    }
    $('code').value = code;
    $('pairErr').classList.add('hidden');
    $('doPair').disabled = true;
    // 明确反馈「正在连接」：扫码后自动配对时，用户不该面对一个静默等待的界面
    setConn(false, '正在连接电视…');
    fetch('/api/pair', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({code: code, label: LABEL})
    }).then(function (r) { return r.json().then(function (j) { return [r.status, j]; }); })
      .then(function (res) {
        var status = res[0], body = res[1];
        if (status === 200 && body.token) {
          token = body.token;
          try { localStorage.setItem(TOKEN_KEY, token); } catch (e) {}
          enterRemote();
        } else {
          $('pairErr').textContent = '配对码不正确或已过期，请在电视上重新获取';
          $('pairErr').classList.remove('hidden');
        }
      })
      .catch(function () {
        $('pairErr').textContent = '连不上电视，确认手机与电视在同一局域网';
        $('pairErr').classList.remove('hidden');
      })
      .then(function () { $('doPair').disabled = false; });
  }

  function enterRemote() {
    $('pair').classList.add('hidden');
    $('main').classList.remove('hidden');
    openSocket();
    loadQueue();
    loadBrowse(true);
  }

  // ── WebSocket ───────────────────────────────────────────
  function openSocket() {
    if (!token) return;
    var proto = location.protocol === 'https:' ? 'wss://' : 'ws://';
    try { ws = new WebSocket(proto + location.host + '/ws?token=' + encodeURIComponent(token)); }
    catch (e) { setTimeout(openSocket, 3000); return; }

    ws.onopen = function () { reconnectDelay = 1000; setConn(true, '已连接电视'); };
    ws.onmessage = function (ev) {
      var msg;
      try { msg = JSON.parse(ev.data); } catch (e) { return; }
      if (msg.type === 'state') { applyState(msg.data); }
      else if (msg.type === 'ack' && msg.ok === false) {
        showErr('操作未生效：' + (msg.error || '未知错误'));
      }
    };
    ws.onclose = function () {
      setConn(false, '连接断开，正在重连…');
      ws = null;
      // 指数退避，最多 15 秒一次；凭证失效时 fail() 会切回配对界面
      setTimeout(function () {
        reconnectDelay = Math.min(reconnectDelay * 2, 15000);
        if (token) openSocket();
      }, reconnectDelay);
    };
    ws.onerror = function () { setConn(false, '连接异常'); };
  }

  function showErr(msg) {
    $('cmdErr').textContent = msg;
    $('cmdErr').classList.remove('hidden');
    setTimeout(function () { $('cmdErr').classList.add('hidden'); }, 4000);
  }

  // ⚠️ 命令 id 必须「每个页面实例唯一 + 单调递增」。
  //    原来用 'c1','c2'…，而服务端会按 id 去重（抗弱网重发的切歌指令）。
  //    页面刷新后 seq 归零 → 新的 'c1' 被当成「重发过的旧命令」直接忽略，
  //    表现就是：**明明显示已连接，按钮按了却没反应**。
  //    加一段每次加载都不同的随机前缀即可根治，同时保留同一次重试复用原 id 的能力。
  var SESSION_ID = Math.random().toString(36).slice(2, 10);

  function cmd(name, args) {
    if (!token) return Promise.resolve();
    var payload = {type: 'cmd', cmd: name, args: args || {}, id: SESSION_ID + '-' + (++seq)};
    if (ws && ws.readyState === 1) {
      ws.send(JSON.stringify(payload));
      return Promise.resolve();
    }
    return api('/api/cmd', {method: 'POST', body: JSON.stringify(payload)})
      .then(function (r) { if (r.ok === false) showErr('操作未生效'); })
      .catch(function () { showErr('连不上电视'); });
  }

  // ── 状态渲染 ────────────────────────────────────────────
  function applyState(s) {
    state = s;
    var c = s.current;
    if (!c) {
      $('title').textContent = '未在播放';
      $('meta').textContent = '';
      $('spec').textContent = '';
      $('cover').removeAttribute('src');
      $('play').textContent = '▶';
      return;
    }
    $('title').textContent = c.title;
    $('meta').textContent = (c.artist || '') + (c.album ? ' · ' + c.album : '');
    $('spec').textContent = c.spec || '';
    $('cover').src = c.coverId
      ? '/api/cover?id=' + encodeURIComponent(c.coverId) + '&size=200&token=' + encodeURIComponent(token)
      : '';
    $('fav').textContent = c.favorite ? '♥' : '♡';
    $('fav').style.color = c.favorite ? '#FF3B30' : '#fff';
    $('play').textContent = s.isPlaying ? '⏸' : '▶';
    $('mode').textContent = modeLabel[s.mode] || '顺序';
    if (!seeking) {
      var dur = s.durationMs || c.durationMs || 0;
      $('dur').textContent = fmt(dur);
      $('pos').textContent = fmt(s.positionMs);
      $('seek').value = dur > 0 ? Math.round(s.positionMs * 1000 / dur) : 0;
    }
    // 队列里高亮当前项
    var items = document.querySelectorAll('#queueList li');
    for (var i = 0; i < items.length; i++) {
      items[i].className = (Number(items[i].dataset.index) === s.index) ? 'cur' : '';
    }
    $('queueHint').textContent = '共 ' + s.queueLength + ' 首 · 来源：' + (s.sourceLabel || '');
  }

  // ── 列表渲染 ────────────────────────────────────────────
  function rowHtml(item, index, withIndex) {
    var cover = item.coverId
      ? '<img src="/api/cover?id=' + encodeURIComponent(item.coverId) + '&size=100&token=' + encodeURIComponent(token) + '">'
      : '<img>';
    var sub = (item.artist || '') + (item.album ? ' · ' + item.album : '');
    return '<li data-index="' + (index == null ? '' : index) + '" data-guid="' + item.guid + '">'
      + cover + '<div style="min-width:0;flex:1"><div class="li-t">' + esc(item.title)
      + '</div><div class="li-s">' + esc(sub) + '</div></div>'
      + (withIndex ? '' : '<span style="color:var(--faint)">' + fmt(item.durationMs) + '</span>')
      + '</li>';
  }

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (m) {
      return ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'})[m];
    });
  }

  function loadQueue() {
    api('/api/cmd', {method: 'POST', body: JSON.stringify({cmd: 'queue', args: {offset: 0, limit: 200}, id: 'q' + (++seq)})})
      .then(function (r) {
        queueItems = r.items || [];
        var html = '';
        for (var i = 0; i < queueItems.length; i++) { html += rowHtml(queueItems[i], i, false); }
        $('queueList').innerHTML = html || '<li>队列为空</li>';
      })
      .catch(function () {});
  }

  function loadBrowse(reset) {
    if (reset) { browseOffset = 0; browseItems = []; }
    api('/api/cmd', {method: 'POST', body: JSON.stringify({cmd: 'browse', args: {offset: browseOffset, limit: 60}, id: 'b' + (++seq)})})
      .then(function (r) {
        var items = r.items || [];
        browseItems = browseItems.concat(items);
        browseOffset += items.length;
        var html = '';
        for (var i = 0; i < browseItems.length; i++) { html += rowHtml(browseItems[i], null, false); }
        $('browseList').innerHTML = html || '<li>曲库为空</li>';
        $('browseHint').textContent = '已显示 ' + browseItems.length + ' 首'
          + (items.length === 0 ? '（已到底）' : '，滚到底自动继续');
      })
      .catch(function () {});
  }

  function doSearch() {
    var q = ($('q').value || '').trim();
    if (!q) { loadBrowse(true); return; }
    api('/api/cmd', {method: 'POST', body: JSON.stringify({cmd: 'search', args: {q: q}, id: 's' + (++seq)})})
      .then(function (r) {
        var items = r.items || [];
        browseItems = items;
        var html = '';
        for (var i = 0; i < items.length; i++) { html += rowHtml(items[i], null, false); }
        $('browseList').innerHTML = html || '<li>没有匹配的歌曲</li>';
        $('browseHint').textContent = '找到 ' + items.length + ' 首';
      })
      .catch(function () {});
  }

  // ── 事件绑定 ────────────────────────────────────────────
  $('doPair').addEventListener('click', doPair);
  $('code').addEventListener('keydown', function (e) { if (e.key === 'Enter') doPair(); });
  $('play').addEventListener('click', function () { cmd('toggle'); });
  $('prev').addEventListener('click', function () { cmd('previous'); });
  $('next').addEventListener('click', function () { cmd('next'); });
  $('mode').addEventListener('click', function () {
    var cur = (state && state.mode) || 'sequence';
    var i = modeOrder.indexOf(cur);
    cmd('mode', {value: modeOrder[(i + 1) % modeOrder.length]});
  });
  $('refresh').addEventListener('click', function () { loadQueue(); loadBrowse(true); });
  $('fav').addEventListener('click', function () {
    if (state && state.current) cmd('favorite', {guid: state.current.guid});
  });
  $('unpair').addEventListener('click', function () {
    fail('已解除配对，需要重新在电视上获取配对码');
  });
  $('seek').addEventListener('input', function () { seeking = true; });
  $('seek').addEventListener('change', function () {
    if (!state) { seeking = false; return; }
    var dur = state.durationMs || (state.current ? state.current.durationMs : 0) || 0;
    var ms = Math.round(dur * Number($('seek').value) / 1000);
    cmd('seek', {positionMs: ms});
    setTimeout(function () { seeking = false; }, 600);
  });
  $('tabQueue').addEventListener('click', function () {
    $('tabQueue').classList.add('on'); $('tabBrowse').classList.remove('on');
    $('paneQueue').classList.remove('hidden'); $('paneBrowse').classList.add('hidden');
  });
  $('tabBrowse').addEventListener('click', function () {
    $('tabBrowse').classList.add('on'); $('tabQueue').classList.remove('on');
    $('paneBrowse').classList.remove('hidden'); $('paneQueue').classList.add('hidden');
    if (browseItems.length === 0) loadBrowse(true);
  });
  $('q').addEventListener('keydown', function (e) { if (e.key === 'Enter') doSearch(); });
  $('browseList').addEventListener('scroll', function (e) {
    var el = e.target;
    if (el.scrollTop + el.clientHeight >= el.scrollHeight - 40) {
      if (($('q').value || '').trim() === '') loadBrowse(false);
    }
  });
  document.addEventListener('click', function (e) {
    var li = e.target.closest ? e.target.closest('li[data-guid]') : null;
    if (!li) return;
    var guid = li.getAttribute('data-guid');
    if (!guid) return;
    var idxAttr = li.getAttribute('data-index');
    if (idxAttr !== '' && idxAttr !== null) cmd('select', {index: Number(idxAttr)});
    else cmd('playGuid', {guid: guid});
    setTimeout(loadQueue, 500);
  });

  // ── 启动 ────────────────────────────────────────────────
  // 二维码里带了 `#CODE`（fragment 不会发给服务端）。
  var hash = (location.hash || '').replace('#', '').trim().toUpperCase();
  try { location.hash = ''; } catch (e) {}
  try { token = localStorage.getItem(TOKEN_KEY); } catch (e) { token = null; }

  if (hash.length === 6) {
    // ⚠️ **新配对码优先于本地旧 token**。
    //    旧 token 很可能已被服务端撤销（在电视上重新配对过 / 登出过），
    //    如果先拿它去连，用户会先看到一个失败态，再被告知"请重新配对"。
    //    有码就直接配对 —— 而且**自动执行**，不让用户再点一次按钮。
    $('code').value = hash;
    doPair(hash);
  } else if (token) {
    // 没有新码时才复用本地凭证，并且**先校验**：
    //    GET /api/state 返回 401 就清掉旧凭证回到配对界面，
    //    而不是带着一个失效 token 去无限重连（用户会一直看到"正在重连…"）。
    setConn(false, '正在校验连接…');
    api('/api/state').then(function () {
      enterRemote();
    }).catch(function () {
      fail('上次的配对已失效，请输入电视上显示的配对码');
    });
  } else {
    $('pair').classList.remove('hidden');
    setConn(false, '未连接');
  }
})();
</script>
</body>
</html>
''';
