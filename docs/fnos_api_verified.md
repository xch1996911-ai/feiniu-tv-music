# 飞牛 fnOS 音乐 API 验证文档（fnos_api_verified.md）

> 阶段：Phase 1
> 更新日期：2026-10-02（真实契约修正）
> **最高优先级事实来源：[fnOS_API_真实契约.md](./fnOS_API_真实契约.md)（真实 NAS 实测版）**
> 关联：[technical_research.md](../technical_research.md) §2、[tools/fnos_api_probe](../tools/fnos_api_probe)

## 0. 重要声明

Phase 1 早期本文件所有接口状态均为 `UNVERIFIED`（研究整理）。**现已完成真实 NAS 实测**：

- 被测设备：飞牛 fnOS 音乐应用（`serverVersion 1.0.10` / `mediasrvVersion 0.8.42`），API 基址 `http://<NAS>:5666/music/api/v1`（本文件已对 NAS 地址脱敏）。
- 验证方式：① 逆向 NAS 上运行的官方 Web 客户端 3.4 MB JS bundle；② 用验证脚本对该 NAS 真实登录并逐接口实测。
- **凡本文件与 `technical_research.md` / 早期 `docs` 推测冲突之处，一律以实测为准。**
- 剩余未实测项（歌词响应字段细节、写接口）在 §5 明确标注，**不得**当作已验证。

## 1. 探针 / 验证脚本使用方法

自包含 Windows EXE（无需 Dart/Flutter）：

```powershell
.\fnos_api_probe.exe            # 交互式输入 Host / 用户名 / 密码（密码不回显）
```

源码方式：

```bash
cd tools/fnos_api_probe
dart pub get
dart run bin/probe.dart --host http://<NAS局域网IP>:5666 --username <账号>
# 密码走交互式隐藏输入，不通过命令行传递
```

报告输出 `probe_report_redacted.md` / `fnos_verify_report.md`，自动脱敏 IP / 用户名 / token / Cookie。

## 2. 接口验证表（Phase 1 使用的 9 个接口全部 VERIFIED）

| # | 接口 | 方法 | 路径 | 状态 | 实测结论 |
|---|---|---|---|---|---|
| 1 | 连接探测 | GET | `/music/api/v1/initialization/state` | ✅ **VERIFIED** | **免鉴权**，返回 `initialized: true` / `serverName` / `serverVersion 1.0.10` / `mediasrvVersion 0.8.42` / `capabilities` |
| 2 | 密码登录 | POST | `/music/api/v1/user/password-login` | ✅ **VERIFIED** | body 必需 **三个**字段：`username` / `password=SHA256(明文)小写hex` / `deviceId=32位小写hex`；成功返回 `data.userToken` + `data.user` |
| 3 | 当前用户 | GET | `/music/api/v1/user/me` | ✅ **VERIFIED** | 需认证；字段 `guid/name/role/lastAccessedAt/createdAt/updatedAt`（时间戳为 **Unix 秒**） |
| 4 | 曲目列表 | GET | `/music/api/v1/track/list` | ✅ **VERIFIED** | 分页 **`page` + `size`**（`pageSize` / `limit` 被忽略，默认 50）；返回 `{list,total,sort}` |
| 5 | 专辑列表 | GET | `/music/api/v1/album/list` | ✅ **VERIFIED** | 同分页结构；键集 `guid/name/coverId/releaseDate/barcode/createdAt/updatedAt/artists/trackCount` |
| 6 | 歌手列表 | GET | `/music/api/v1/artist/list` | ✅ **VERIFIED** | 同分页结构；键集 `guid/name/coverId/createdAt/updatedAt/trackCount/albumCount`（`artist/list-all` 字段更少） |
| 7 | 歌词列表 | GET | `/music/api/v1/lyric/list` | ✅ **VERIFIED** | ⚠️ 参数名是 **`trackGUID`**（大写 GUID），用 `guid` 会返回 `100002 InvalidArgs`；返回 `{list, preferred}` |
| 8 | 音频流 | GET | `/music/api/v1/track/stream?guid=` | ✅ **VERIFIED** | HTTP 200 `audio/flac`；带 `Range: bytes=0-1023` → **HTTP 206**，即服务端完整支持 Range |
| 9 | 封面 | GET | `/music/api/v1/static/cover?coverId=<含前缀>&size=` | ✅ **VERIFIED** | `coverId` 必须是**含前缀的完整值**（`album_` / `artist_` / `track_`）；`size` 可选，官方枚举 200/120/60/100 |

**通用信封**：`{ "code": 0, "msg": "", "data": {...} }`；`code == 0` 成功。

⚠️ **错误码语义修正**（Phase 1 早期结论错误，已纠正）：

| 码 | 真实含义 | 本 App 处置 |
|---|---|---|
| **99999**（HTTP 401） | 缺少 / 无效 `music-token` Cookie | `ErrorKind.tokenExpired` → 有密码哈希则静默重登 |
| **120001** | **凭据错误 / 授权失败**（`unauthorized, please login again`） | `ErrorKind.auth` → 必须让用户重新输入凭据 |

两者**不合并**：早期把 `120001` 当作「token 失效」是错的。
完整错误码表见 `fnOS_API_真实契约.md` §2 与 `lib/servers/fnos/fnos_error_codes.dart`。

## 3. 认证机制（已实测判定）

| 方案 | 结论 |
|---|---|
| A. Cookie `music-token=<token>` | ✅ **硬门槛**。缺失 → `HTTP 401 {"code":99999,"msg":"INVALID TOKEN"}` |
| B. `authx` 签名头 | ⚠️ 官方 Web 客户端每请求都带，但**该 NAS 未强校验**。已按官方算法实现为**兼容层**，与 Cookie 解耦；签名失败不影响 Cookie 认证 |
| C. 二者并存 | 实际形态：Cookie 认证 + authx 兼容签名（同时发出，互不影响） |

`authx` 算法（逆向自官方前端 bundle，盐值 `NDzZTVxnRKP8Z0jXg1VAMonaG8akvh`）：

```
GET  : payload  = query 按 key 字典序规范化，'+' → '%20'
       bodyHash = MD5(decodeURIComponent(payload))
非GET: bodyHash = MD5(JSON.stringify(data))     // data 为 null 时用 ''
sign = MD5([SALT, pathname, nonce, timestamp, bodyHash, apiKey].join('_'))
       nonce = 6 位数字 [100000,999999]，timestamp = 毫秒
```

免签名白名单：`/client-login`、`/app-auth-pick-file`、`/init`、`/login`、`/oauth/result`、`/welcome`。
实现与黄金向量测试：`lib/servers/fnos/fnos_authx.dart`、`test/fnos_authx_test.dart`。

## 4. 数据模型字段（真实契约 §5，已按实测修正）

- **Track**：`guid, title, coverId(含前缀), year(实测 null), discNo, trackNo, isrc, duration(ms), isCue, isFavorite, genres[], createdAt/updatedAt(Unix 秒), album{guid,name,coverId,releaseDate,barcode,时间戳}, artists[{guid,name,coverId,时间戳}], audioSpec{format,codec,container,bitDepth,sampleRate,channel,bitrate,size,duration(ms)}`
- **Album**：`guid, name, coverId, releaseDate(字符串，如 "2002"), barcode, 时间戳, artists[], trackCount`
- **Artist**：`guid, name, coverId, 时间戳, trackCount, albumCount`
- **User**：`guid, name, role, lastAccessedAt, createdAt, updatedAt`（Unix 秒）

### 与早期假设的差异（**已修正**，见 `lib/domain/*.dart`）

| 早期假设 | **实测真实** |
|---|---|
| `id` | **`guid`** |
| `artistNames`（String） | **`artists: List<ArtistRef>`**（`guid`/`name`/`coverId`/时间戳） |
| `album.originalReleaseYear` | **`album.releaseDate`**（String，如 `"2002"`） |
| `audioSpec.channels` | **`audioSpec.channel`**（单数） |
| `duration` 单位待定 | **毫秒**（实测 218711ms = 218.7s ≈ 3′39″） |
| 时间戳单位待定 | **Unix 秒**（毫秒会让时间跑到 1970-01-21） |
| 封面 `size=800` | **`size` 可选**，官方枚举 200/120/60/100（默认取 200） |
| 歌词参数 `guid` | **`trackGUID`**（大小写敏感） |
| 分页 `pageSize`/`limit` | **`page` + `size`** |
| `120001` = token 失效 | **`99999`(HTTP 401) = token 失效**；`120001` = 凭据错误 |

**封面优先级**：`track.coverId` → `track.album.coverId`（即 `Track.effectiveCoverId`）。
`accessStatus == 3` → 音频文件失效（不可播）。该字段与 `hasLyric` **未在实测样本中出现**，属保留字段。

## 5. 已知风险 / 仍未实测项

| # | 项 | 状态 |
|---|---|---|
| 1 | 歌词响应内元素字段细节（`text` 是否承载整段 LRC） | ⚠️ **尚未取到样本**；解析器对 LRC 与单行两种形态都兼容（`lib/domain/lyric.dart`） |
| 2 | 逐字歌词（karaoke）是否存在 | 未验证；Phase 1 明确不做 |
| 3 | 收藏 / 歌单写接口（`playlist/*`、`favorite-track/*`） | 仅逆向确认路径，属 Phase 2 |
| 4 | 自签 HTTPS（5667）在 TV 设备的证书豁免差异 | 未验证（本次实测走 HTTP 5666） |
| 5 | `flutter_secure_storage` 在国产盒子上的可用性 | 未验证（真机待测） |
| 6 | 飞牛固件更新可能变更 API | 持续风险；用 `initialization/state` 的版本字段探测 |
| 7 | 音频 Seek 在真实 TV 设备上的表现 | 服务端 Range(206) 已确认，客户端待真机播放测试 |

## 6. 回填规范

新增验证结论时：更新 §2 表格状态与实测结论，并同步更新 `fnOS_API_真实契约.md`。
**不得**把未经真机验证的推测写成 `VERIFIED`。新增契约差异时，必须同时补 `test/fnos_client_test.dart` / `test/fnos_models_test.dart` 中的契约测试。
