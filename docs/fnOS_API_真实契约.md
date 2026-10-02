# fnOS 音乐 API 真实契约（实机验证版）

> 说明：本文件是仓库内的自洽副本，来源为工作区根目录的 `fnOS_API_真实契约.md`。
> 仅把真实 NAS 局域网地址替换为 `<NAS>`（脱敏），技术结论与实测数据完全一致。
> 该文件是本项目 API 事实的**最高优先级来源**。

> **来源与可信度**
> - 逆向自 NAS 上运行的官方网页版音乐播放器前端（`http://<host>:5666/music/`，3.4 MB JS bundle）
> - **所有关键结论均已在真实 NAS `<NAS>:5666` 上实测登录并验证**
> - 验证时间：2026-10-02 21:28 ~ 21:33
> - 验证脚本：`fnos_verify.py`（报告 `fnos_verify_report.md`）

---

## 0. 环境事实（实测）

| 项 | 值 |
|---|---|
| NAS 地址 | `http://<NAS>:5666` |
| Server | nginx |
| 音乐 App | 已启用（`initialized: true`） |
| serverName | `ADMIN` |
| serverVersion | `1.0.10` |
| mediasrvVersion | `0.8.42` |
| capabilities | `{ folderView: false, libraryReconnect: true }` |
| API 基址 | `http://<host>:5666/music/api/v1` |

---

## 1. 认证机制（实测确认）

### 1.1 结论
| 项 | 状态 |
|---|---|
| **Cookie `music-token=<token>`** | ✅ **硬门槛**，缺失 → `401 {"code":99999,"msg":"INVALID TOKEN"}` |
| **`authx` 签名头** | ⚠️ 官方客户端每请求都带；**实测该 NAS 未强校验**（建议实现以保证长期兼容） |
| **免鉴权接口** | `/initialization/state`、`/sys/config` |

### 1.2 登录（实机成功）

`POST /music/api/v1/user/password-login`

**真实响应**（已脱敏）：
```json
{
  "code": 0,
  "msg": "",
  "data": {
    "userToken": "<32 位小写 hex>",
    "user": {
      "guid": "<32位hex>",
      "name": "<用户名>",
      "role": "admin",
      "lastAccessedAt": 1789831867,
      "createdAt": 1788189112,
      "updatedAt": 1789831873
    }
  }
}
```

**三个必需字段**：

| 字段 | 生成方式 |
|---|---|
| `username` | `trim()` |
| `password` | **SHA256(明文密码)** 小写 hex |
| `deviceId` | **32 位小写 hex**，生成一次后持久化复用 |

> ⚠️ **token 在 `data.userToken`**，不是 `result.token`。
> （前端 `handleAuthenticatedUser({userToken: e.result.token})` 是桌面端桥接层的形状，
> 网页版直连 NAS 时响应结构为 `data.userToken`。**两者都要兼容**。）
>
> `userToken` 长度 **32**（十六进制串，**不是 JWT**）。

**`deviceId` 生成逻辑**（前端 `Ek()`）：
```js
Ck = 32
Tk = () => {
  if (crypto.randomUUID) return crypto.randomUUID().replace(/-/g, '');       // 32 hex
  let e = new Uint8Array(16);
  crypto.getRandomValues(e);
  return Array.from(e, x => x.toString(16).padStart(2, '0')).join('');      // 32 hex
}
Ek = () => {
  let cached = localStorage.getItem(Sk);
  if (cached && /^[a-f0-9]{32}$/i.test(cached)) return cached;
  let id = Tk().slice(0, 32);
  localStorage.setItem(Sk, id);
  return id;
}
```
→ App 侧应生成一次并用 `flutter_secure_storage` 持久化。

**错误码对照（实测）**：
| 情况 | 响应 |
|---|---|
| 缺 `deviceId` | `{"code":100001,"msg":"unknown error"}` |
| 凭据错误 | `{"code":120001,"msg":"unauthorized, please login again"}` |
| **登录成功** | `{"code":0,"msg":"","data":{"userToken":...,"user":...}}` |

### 1.3 `authx` 签名算法（完整逆出）

```js
// 前端核心库 mj_9 bundle
Lt = SparkMD5                                    // ⚠️ 是 MD5，不是 SHA256
SALT = 'NDzZTVxnRKP8Z0jXg1VAMonaG8akvh'         // 硬编码盐值

yO = (query) => {                                 // GET 查询串规范化
  const p = new URLSearchParams();
  for (const k of Object.keys(query).sort()) {    // 按 key 字典序
    const v = query[k];
    if (v != null) p.append(k, String(v));
  }
  return p.toString().replace(/\+/g, '%20');      // '+' → '%20'
}
bO = (url) => {                                   // 拆 pathname 与 query
  const u = new URL(url, 'http://fetch-client.local');
  const q = {};
  u.searchParams.forEach((v, k) => {
    if (v !== 'undefined' && v !== 'null') q[k] = v;   // 丢弃 undefined/null
  });
  return [u.pathname, q];
}
xO = (s = '') => {                                // GET 的 hash
  try { return MD5(decodeURIComponent(s.replace(/%(?![0-9A-Fa-f]{2})/g, '%25'))); }
  catch { return MD5(s); }
}
SO = (s = '') => MD5(s);                          // 非 GET 的 hash

CO = (e, t = '') => {                             // 主函数
  const isGet = e.method.toUpperCase() === 'GET';
  const [pathname, query] = bO(e.url);
  const payload = isGet ? yO(query) : (e.data == null ? '' : JSON.stringify(e.data));
  const bodyHash = isGet ? xO(payload) : SO(payload);
  const nonce     = `${Math.floor(Math.random() * 9e5) + 1e5}`;   // 6 位 [100000,999999]
  const timestamp = `${Date.now()}`;                               // ms
  const raw = [SALT, pathname, nonce, timestamp, bodyHash, t].join('_');
  return `nonce=${nonce}&timestamp=${timestamp}&sign=${MD5(raw)}`;
}
// 用法：header['authx'] = CO(request, apiKey)   // Web 端 apiKey = ''
```

**免签名白名单**：`/client-login`、`/app-auth-pick-file`、`/init`、`/login`、`/oauth/result`、`/welcome`

### 1.4 Cookie 设置（前端）
```js
UO = 'music-token'
document.cookie = `${UO}=${encodeURIComponent(token)}; Path=/; SameSite=Strict`
```
清除：`document.cookie = `${UO}=; Path=/; Max-Age=0; SameSite=Strict``

---

## 2. 业务错误码表（从前端逆向，可直接用于错误处理）

| 码 | 名称 | 含义 |
|---|---|---|
| 0 | — | 成功 |
| 100001 | Unknown | 未知错误（**含参数缺失**，如缺 deviceId） |
| 100002 | InvalidArgs | 参数无效（如 lyric/list 缺 trackGUID） |
| 100003 | AdminRequired | 需要管理员权限 |
| 100004 | Forbidden | 禁止访问 |
| 100005 | NotFound | 资源不存在 |
| 110001 | AppAlreadyInitialized | App 已初始化 |
| 110002 | AppNotInitialized | App 未初始化 |
| 110003 | InitRequiresNASAdmin | 初始化需 NAS 管理员 |
| 110004 | InitSessionNotFound | 初始化会话不存在 |
| **120001** | **Unauthorized** | **未授权 / 凭据错误（登录失败即此码）** |
| 120002 | UserDisabled | 用户被禁用 |
| 120003 | OAuthUserAlreadyExists | OAuth 用户已存在 |
| 120004 | UsernameExists | 用户名已存在 |
| 120005 | InvalidUsername | 用户名无效 |
| 120006 | PasswordRequired | 需要密码 |
| 130001 | CueMissingOffset | CUE 文件缺 offset |
| 140001 | SearchIndexRebuildInProgress | 搜索索引重建中 |
| 150001-150005 | SharedLibrary* | 共享音乐库相关 |
| 160001 | PlaylistNameExists | 播放列表名已存在 |
| 160002 | PlaylistHitMaxCount | 播放列表数量达上限 |
| **99999** | **INVALID TOKEN** | **HTTP 401，缺少/无效 `music-token` Cookie** |

---

## 3. 列表响应结构（实测）

**所有 list 接口结构一致**：
```json
{ "code": 0, "msg": "", "data": { "list": [...], "total": <总数>, "sort": <排序> } }
```

### 分页参数（实机探测结论）
| 请求 | 返回条数 | 结论 |
|---|---|---|
| `?page=1&size=5` | **5** | ✅ `size` 生效 |
| `?page=1&pageSize=5` | 50 | `pageSize` 被忽略 |
| `?page=1&limit=5` | 50 | `limit` 被忽略 |
| `?page=1` | 50 | 默认 50 |
| 无参数 | 50 | 默认 50 |

> ✅ **正确用法：`?page=<页码>&size=<每页条数>`**，默认 `size=50`。

---

## 4. duration 单位：**毫秒（ms）** —— 已实机确认

**实测样本**（孙燕姿《Leave》/ 作战，FLAC）：
```json
"duration": 218711,                              // 顶层
"audioSpec": { "duration": 218711, ... }         // 与顶层一致
```
`218711 ms = 218.7 秒 ≈ 3 分 39 秒` —— 符合正常歌曲长度，**确认毫秒**。

前端权威映射：
```js
duration: Math.round(e.duration / 1e3)   // 毫秒 → 秒
```

| 字段 | 单位 |
|---|---|
| `duration`（顶层 & `audioSpec.duration`） | **毫秒** |
| `createdAt` / `updatedAt`（track/album/artist 全部） | **Unix 秒** |
| `size` | 字节 |

---

## 5. 实体字段（实机完整样本）

### 5.1 Track
```json
{
  "guid": "190294f1459e486291cab74dfc8da470",
  "title": "作战",
  "coverId": "album_659bfc696e7045bb85f07eb45022c0f2",
  "year": null,
  "discNo": 1,
  "trackNo": 1,
  "isrc": "TWA530224201",
  "duration": 218711,
  "isCue": false,
  "createdAt": 1788283180,
  "updatedAt": 1788283180,
  "album": {
    "guid": "<hex>",
    "name": "Leave",
    "coverId": "album_659bfc696e7045bb85f07eb45022c0f2",
    "releaseDate": "2002",
    "barcode": "825646671045",
    "createdAt": 1788283180,
    "updatedAt": 1788283180
  },
  "artists": [
    { "guid": "<hex>", "name": "孙燕姿",
      "coverId": "artist_f68ba53c0fbf413cafe03b9d19eff378",
      "createdAt": 1788262195, "updatedAt": 1788262195 }
  ],
  "genres": [],
  "audioSpec": {
    "bitDepth": 16,
    "sampleRate": 44100,
    "channel": 2,                    // ⚠️ channel 单数
    "bitrate": 962854,
    "codec": "flac",
    "container": "",
    "duration": 218711,
    "format": "flac",
    "path": "/vol2/1000/音乐/.../01 作战.flac",
    "size": 26322832
  },
  "isFavorite": false
}
```

### ⚠️ 与原 Phase 1 模型的差异（必须改）
| Phase 1 假设 | **实测真实** |
|---|---|
| `id` | **`guid`** |
| `artistNames` (String) | **`artists: List<Object>`**（`guid`/`name`/`coverId`/时间戳） |
| `album.originalReleaseYear` | **`album.releaseDate`**（String，如 `"2002"`） |
| 顶层 `year` | 存在但实测 `null`，真实年份在 `album.releaseDate` |
| `audioSpec.channels` | **`audioSpec.channel`**（单数） |
| — | 新增字段：`isrc` / `isFavorite` / `genres` / `isCue` / `coverId`(带前缀) |

### 5.2 Album（实测）
`['guid', 'name', 'coverId', 'releaseDate', 'barcode', 'createdAt', 'updatedAt', 'artists', 'trackCount']`

### 5.3 Artist（实测）
`['guid', 'name', 'coverId', 'createdAt', 'updatedAt', 'trackCount', 'albumCount']`

> `artist/list` 与 `artist/list-all` 字段不同：后者只有 `guid`/`name`/`coverId`/时间戳（用于下拉选择）。

---

## 6. 封面接口

**`GET /static/cover?coverId=<coverId>&size=<size>`**

- `coverId` 格式：**`<类型>_<32位hex>`**，实测三种前缀：
  - `album_659bfc696e7045bb85f07eb45022c0f2`
  - `artist_f68ba53c0fbf413cafe03b9d19eff378`
  - `track_14d9ec74caf84915a56cf19a382afd34`
- **传整个 coverId（含前缀），不要拆分**
- `size` 可选（前端枚举：`200` / `120` / `60` / `100`）

前端 URL 构造源码：
```js
ei = (e, t = {}) => {
  const n = new URLSearchParams({ coverId: e });
  const r = Xr(t.size);
  if (r !== undefined) n.set('size', String(r));
  return `${apiRoot}/static/cover?${n.toString()}`;
};
```

**封面优先级**（前端 `Qi()`）：`track.coverId` → `track.album.coverId`

---

## 7. 歌词接口

**`GET /lyric/list?trackGUID=<track_guid>`**

⚠️ **参数名是 `trackGUID`（大写 GUID）**，不是 `guid` —— 用 `guid` 会返回 `100002 InvalidArgs`。

前端调用：
```js
let t = await api.lyric.list({ trackGUID: trackId }, {...});
return { lyrics: pickPreferred(t?.list, t?.preferred) };
```

**返回结构**：`{ list: [...], preferred: <引用> }`
- `list` — 多个歌词源
- `preferred` — 当前生效歌词
- 单条歌词含 `text` / `time`（**秒**） / `duration` / `offset`
- 前端还处理 `metadata.offset`（整体偏移）与用户手动微调 `offsetSeconds`

---

## 8. 音频流与 Seek（实机确认）

| 项 | 实测结果 |
|---|---|
| `GET /track/stream?guid=<guid>` | **HTTP 200**，`Content-Type: audio/flac`，26322832 bytes，2370ms |
| `GET /track/stream` + `Range: bytes=0-1023` | **HTTP 206**，1024 bytes |

✅ **服务端完整支持 Range → `just_audio` 可直接 Seek，无需自己实现分块下载。**

---

## 9. 完整 API 路径表

### 免鉴权
```
GET  /initialization/state
GET  /sys/config
```

### 认证
```
POST /user/password-login      { username, password(SHA256), deviceId(32hex) }
POST /user/auth-login
GET  /user/me
POST /user/logout
POST /user/passwd-change
GET  /user/unbanned
POST /user/exists  /user/create  /user/delete  /user/edit  /user/list
```

### 曲库（需 token）
```
GET  /track/list?page=&size=          ✅ 实测
GET  /track/stream?guid=              ✅ 实测（支持 Range 206）
GET  /track/metadata?guid=            ✅ 实测
GET  /track/album-detail-list?guid=
GET  /track/artist-detail-list?guid=
GET  /track/genre-detail-list?guid=
GET  /track/playlist-detail/list
POST /track/metadata                  (更新元数据)
POST /track/transcode  /track/transcode/heartbeat  /track/transcode/quit
GET  /track/roam-start  /track/roam-next  /track/roam-previous
GET  /track/hls/:guid/preset.m3u8     (HLS)

GET  /album/list?page=&size=          ✅ 实测
GET  /album/detail?guid=              ✅ 实测
GET  /album/artist-detail-list

GET  /artist/list?page=&size=         ✅ 实测
GET  /artist/list-all                 ✅ 实测
GET  /artist/detail?guid=
POST /artist/create

GET  /lyric/list?trackGUID=           ⚠️ 参数名 trackGUID
GET  /genre/list   /genre/detail?guid=

GET  /static/cover?coverId=&size=     ✅ 参数名 coverId（含前缀）
GET  /static/cover/playlist
POST /static/cover/track              (上传封面)

GET  /playlist/list  /playlist/detail?guid=  /playlist/batch-detail
POST /playlist/create  /playlist/edit  /playlist/delete
POST /playlist/add-track  /playlist/purge-track  /playlist/purge-track-count

GET  /favorite-track/list  /favorite-track/purge-track-count
POST /favorite-track/create  /favorite-track/delete  /favorite-track/purge-track

GET  /play-history/list      POST /play-history/delete

GET  /shared-library/scan  /shared-library/scan-all  /shared-library/reconnect-check
GET  /task/list  /task/retry  /task/cancel  /task/delete
GET  /app-center/authed-dir-list  /app-center/authed-dir-sub-list  /app-center/authed-dir-sub-create
GET  /settings/...    /search/...
```

### API 基址常量（前端）
```js
EO = `${TO}/api/v1`        // 实际使用（AO = EO）
DO = `${TO}/api/intl/v1`
OO = `${TO}/api/intl/v2`
kO = `${TO}/api/v2`
```

---

## 10. 对 Phase 1 App 的改造清单

| 优先级 | 改动 | 文件 |
|---|---|---|
| **P0** | 补 `deviceId`（32位hex，持久化复用） | `lib/servers/fnos/fnos_client.dart` |
| **P0** | 补 `authx` MD5 签名（盐值 `NDzZTVxnRKP8Z0jXg1VAMonaG8akvh`） | 同上 |
| **P0** | token 提取兼容 `data.userToken` / `result.token` | 同上 |
| **P1** | `duration` 按毫秒处理 | `lib/domain/track.dart` |
| **P1** | 字段重命名：`id`→`guid`、`artistNames`→`artists[]`、`album.originalReleaseYear`→`album.releaseDate`、`audioSpec.channels`→`channel` | `lib/domain/*.dart` |
| **P1** | `createdAt`/`updatedAt` 是 Unix 秒 | `lib/domain/track.dart` |
| **P1** | 封面 URL 用 `static/cover?coverId=<含前缀>` | `lib/domain/*.dart` |
| **P2** | 分页用 `page` + `size` | `lib/servers/fnos/fnos_endpoints.dart` |
| **P2** | 歌词用 `lyric/list?trackGUID=` | 同上 |
| **P2** | 补业务错误码枚举与映射 | `lib/core/exceptions.dart` |
| **P2** | 补播放相关接口（playlist / favorite / play-history） | `lib/servers/music_server_provider.dart` |

### 已确认无需改动
- `password` 用 SHA256 —— ✅ Phase 1 已正确实现
- Cookie `music-token` —— ✅ Phase 1 已正确实现
- 登录响应读 `data.userToken` —— ✅ Phase 1 已正确（是我误信前端代码才以为错）
- `track/stream` 支持 Range —— ✅ `just_audio` 直接可用
