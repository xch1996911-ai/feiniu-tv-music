# Phase 1 测试报告（phase1_test_report.md）

> 阶段：Phase 1 — 基础播放闭环
> 报告日期：2026-10-02（真实契约修正版）
> 关联：[fnOS_API_真实契约.md](./fnOS_API_真实契约.md)、[fnos_api_verified.md](./fnos_api_verified.md)、[technical_research.md](../technical_research.md)

## 0. 报告真实性说明

- 本报告**不伪造任何结果**。每一项都标注了它是在哪里被验证的：`CI`（GitHub Actions 实跑）/ `REAL_NAS`（真实 NAS 实测）/ `TV_PENDING`（待电视真机）。
- 本机（开发用 Windows）**无法构建 Flutter**：Dart/Node 运行时无法创建子进程（`CreateFile failed 231 ERROR_PIPE_BUSY`，机器级硬阻断，已逐项排除沙箱/ConPTY/PATH/Dart 版本因素）。因此所有编译/分析/测试/打包**统一走 GitHub Actions**，产物从 `release` 分支取回。
- Phase 1 真机**播放**验证需在电视上完成，尚未进行；本文不把它写成已完成。

---

## 1. 环境信息（已实测回填）

| 项 | 值 | 来源 |
|---|---|---|
| 构建环境 | Flutter **3.47.6** stable（固定版本）+ Temurin **JDK 17** | CI |
| Dart | 3.13.5 | CI |
| Android 构建 | Gradle 9.3.1 + AGP 9.1.0 + Kotlin 2.4.0；compileSdk/targetSdk 36、minSdk 24 | CI |
| 本地工具链 | ⛔ 不可用（Dart spawn 阻断）；Flutter/JDK/Android SDK 已从本机卸载以释放空间 | 本机 |
| **NAS 地址** | `http://<NAS>:5666`（**已脱敏**，局域网） | REAL_NAS |
| **serverVersion** | **1.0.10** | REAL_NAS |
| **mediasrvVersion** | **0.8.42** | REAL_NAS |
| serverName / 角色 | `ADMIN` / `admin` | REAL_NAS |
| capabilities | `{ folderView: false, libraryReconnect: true }` | REAL_NAS |
| **API 基址** | `http://<NAS>:5666/music/api/v1` | REAL_NAS |
| **认证方式** | ✅ Cookie `music-token=<token>`（**硬门槛**）；`authx` 为兼容层，该 NAS 未强校验 | REAL_NAS |
| **deviceId** | ✅ 必需，**32 位小写 hex**，生成一次后持久化复用 | REAL_NAS |
| **duration 单位** | ✅ **毫秒**（实测 218711ms = 218.7s ≈ 3′39″） | REAL_NAS |
| **Range 支持** | ✅ `Range: bytes=0-1023` → **HTTP 206**（26322832 字节 FLAC 全量 200 用时 2370ms） | REAL_NAS |
| 分页参数 | ✅ **`page` + `size`**（`pageSize`/`limit` 被忽略，默认 50） | REAL_NAS |

---

## 2. 构建 / 分析 / 测试（CI 实跑，全绿）

| 检查 | 结果 | 说明 |
|---|---|---|
| `flutter pub get` | ✅ 通过 | 108 个依赖解析成功 |
| `flutter analyze` | ✅ **No issues found!** | 不允许 ignore / 降低严格度 |
| `flutter test` | ✅ 全部通过 | 见 §3；契约测试按真实 NAS 样本新增 |
| `flutter build apk --debug` | ✅ 成功 | `build/app/outputs/flutter-apk/app-debug.apk` |
| `dart analyze --fatal-infos`（probe） | ✅ 通过 | `tools/fnos_api_probe` 独立包 |
| `dart compile exe`（probe） | ✅ 成功 | 自包含 `fnos_api_probe.exe`（目标机无需 Dart/Flutter/Git/Node） |
| CI 失败策略 | ✅ 无 `continue-on-error`、无 analyzer ignore、无删除测试 | 任一失败即整条流水线 FAILED |

---

## 3. 单元 / 契约测试清单（不依赖 NAS，可在 CI 复跑）

| 测试文件 | 覆盖内容 |
|---|---|
| `test/fnos_models_test.dart` | Track/Album/Artist JSON 解析、**duration 毫秒**、`audioSpec.channel`、`album.releaseDate`、`createdAt/updatedAt` Unix 秒、**coverId 保留前缀**、异常类型兜底 |
| `test/fnos_client_test.dart` | **Cookie `music-token`**、authx 头形状、**分页 page+size**、**歌词 trackGUID**、错误码映射（**99999+401 → tokenExpired**、**120001 → auth**、100001/100005）、登录三字段（含 deviceId 32hex）、token 提取优先级（`data.userToken` → `token` → `result.token`）、URL 构造、端点常量 |
| `test/fnos_authx_test.dart` | authx 签名器：规范查询串、`decodeURIComponent` 后取 MD5、六段签名串、**黄金向量**（用独立实现算出的期望值）、nonce 范围、免签名白名单 |
| `test/fnos_ids_test.dart` | deviceId **32 位小写 hex**、唯一性、校验规则 |
| `test/fnos_auth_test.dart` | **SHA256(明文密码)** 小写 hex（64 位）、幂等性 |
| `test/fnos_lyric_test.dart` | LRC 逐行解析（小数位/多标签/offset）、`{list,preferred}` 结构、`preferred` 多种形态 |
| `test/fnos_client_url_test.dart` | 流 URL `guid=`、封面 URL `coverId=`（含前缀，默认 size=200） |
| `test/result_test.dart`、`test/paged_result_test.dart` | Result 代数、分页 hasMore |
| `test/support/fake_adapter.dart` | Dio 离线适配器（拦截并记录真实发出的请求），使上述 HTTP 断言无需联网 |

**测试数据脱敏**：`test/fixtures/fnos_samples.dart` 不含真实 NAS IP / 用户名 / token / 音乐文件绝对路径（`audioSpec.path` 已替换为 `/music/test/01.flac`）。

> 本机另提供 `tools/precheck/dart_syntax_precheck.py`（Python）：在无 Dart 工具链时对括号/字符串闭合做推送前预检，不替代 `dart analyze`。

---

## 4. 真实 NAS 验证结果

| 项目 | 状态 | 实测结论 |
|---|---|---|
| 连接真实飞牛 NAS | ✅ REAL_NAS | `initialization/state` 免鉴权可达，`initialized: true` |
| 登录（SHA256 密码 + deviceId） | ✅ REAL_NAS | 返回 `code:0`，`data.userToken`（32 位 hex）+ `data.user` |
| Cookie 认证 | ✅ REAL_NAS | 带 Cookie 可访问 `user/me`；不带 → `401 {"code":99999}` |
| deviceId 必需性 | ✅ REAL_NAS | 缺失 → `{"code":100001}` |
| 读取曲目列表 | ✅ REAL_NAS | `track/list?page=1&size=5` 返回 5 条；真实字段已用于修正模型 |
| 读取专辑 / 歌手列表 | ✅ REAL_NAS | 键集已确认并写入模型 |
| 歌词接口参数名 | ✅ REAL_NAS | `lyric/list?trackGUID=`；用 `guid` → `100002 InvalidArgs` |
| 封面接口 | ✅ REAL_NAS | `static/cover?coverId=<含前缀>`，前缀不可拆 |
| 音频流 + Range | ✅ REAL_NAS | 200 全量 / **206 分段**（1024 字节）|
| 平均 API 响应时间 | ✅ REAL_NAS | 音频全量 2370ms（26MB FLAC，局域网） |
| **选择真实 NAS 音乐并在电视播放** | ✅ **TV_REAL** | 2026-10-03 海信 E7N Pro 实机播放成功（见 §8） |
| 播放成功 / 失败格式 | 🟡 部分 TV_REAL | **FLAC 16bit/44kHz 已验证成功**；MP3 / AAC 尚未覆盖 |
| 首曲播放启动时间 | ⏳ TV_PENDING | 待电视实测（播放页已出现进度与秒数，但未计时） |
| 遥控 Play/Pause | ⏳ TV_PENDING | 三键已出现且焦点态正确；**暂停后再继续**待确认 |
| 退出播放页不中断 | ⏳ TV_PENDING | 后台 MediaSession 已实现；**返回上级页面后是否继续出声**待确认 |

---

## 5. 真实契约修正（本轮已完成）

| 优先级 | 修正 | 落地文件 |
|---|---|---|
| P0 | 补 `deviceId`（32hex，`flutter_secure_storage` 持久化复用，登出不清除） | `lib/core/ids.dart`、`lib/services/secure_store.dart`、`lib/repositories/auth_repository.dart` |
| P0 | 补 `authx` MD5 签名（盐值按契约），与 Cookie **解耦**为兼容层 | `lib/servers/fnos/fnos_authx.dart`、`lib/servers/fnos/fnos_client.dart` |
| P0 | token 提取：`data.userToken` 优先，兼容 `token` / `result.token` | `lib/servers/fnos/fnos_provider.dart` |
| P1 | `duration` 按毫秒（`Track.durationMs` + `Duration` 视图） | `lib/domain/track.dart` |
| P1 | 字段重命名/补齐：`guid`、`artists[]`、`album.releaseDate`、`audioSpec.channel`、`isrc`、`isFavorite`、`genres`、`isCue`、`coverId` | `lib/domain/{track,album,artist,user}.dart` |
| P1 | `createdAt`/`updatedAt` 按 Unix 秒（毫秒自动收敛） | `lib/domain/json_util.dart` |
| P1 | 封面 URL 用 `static/cover?coverId=<含前缀>`，优先级 track→album | `fnos_client.dart`、`Track.effectiveCoverId` |
| P1 | 歌词接口与逐行歌词模型 | `fnos_endpoints.dart`、`lib/domain/lyric.dart` |
| P1 | 错误码映射与 **99999 / 120001 区分** | `lib/servers/fnos/fnos_error_codes.dart` |
| P2 | 分页统一 `page` + `size` | `fnos_endpoints.dart`、`fnos_provider.dart` |
| — | 流媒体保持 `just_audio`（服务端已支持 Range），**未引入** FFmpeg / media_kit | `lib/playback/playback_engine.dart`（未改动） |

---

## 6. 发现的问题 / 遗留疑点

1. **歌词响应字段细节未取到样本**：`lyric/list` 的 `{list, preferred}` 外层已确认，但 `list` 内元素字段（`text` 是否承载整段 LRC）尚未实测；解析器对 LRC 与单行两种形态都兼容，待真机样本收敛。
2. **`hasLyric` / `accessStatus`**：未在实测样本中出现，保留为缺省字段，**不得**据此判断「无歌词」或「不可播」。
3. **`size` 取值**：官方前端枚举 200/120/60/100；本 App 默认取 200（最大已确认值），未验证的尺寸未使用。
4. **电视端播放链路未验证**：服务端 Range 已确认，客户端 Seek / 遥控 / 后台播放仍需电视实测。
5. **自签 HTTPS / `flutter_secure_storage`** 在国产盒子上的行为未验证（本次实测走局域网 HTTP）。
6. **本机无 Flutter 工具链**：所有验证依赖 CI，本地代码改动推送前无法 `dart analyze`（故附 Python 预检脚本兜底）。

---

## 7. 验收标准对照（Phase 1）

| # | 验收项 | 状态 | 说明 |
|---|---|---|---|
| 1 | Flutter 工程正常编译 | ✅ CI | `flutter pub get` + `build apk --debug` 成功 |
| 2 | `flutter analyze` 无 error | ✅ CI | No issues found! |
| 3 | `flutter test` 通过 | ✅ CI | 契约测试已按真实 NAS 样本扩写 |
| 4 | Android TV / 模拟设备可启动 | ✅ TV_REAL | 2026-10-03 海信 E7N Pro 实机：安装、启动、进入登录页并登录成功（见 §8） |
| 5 | 连接真实飞牛 NAS | ✅ REAL_NAS | `initialization/state` |
| 6 | 可以登录 | ✅ REAL_NAS | SHA256 + deviceId → `data.userToken` |
| 7 | 读取歌曲列表 | ✅ REAL_NAS | `track/list?page=&size=` |
| 8 | 读取专辑列表 | ✅ REAL_NAS | `album/list?page=&size=` |
| 9 | 读取歌手列表 | ✅ REAL_NAS | `artist/list?page=&size=` |
| 10 | 选择真实 NAS 音乐并播放 | ✅ TV_REAL | 2026-10-03 实机播放 `FLAC · 16bit / 44kHz`，进度条与秒数走动（见 §8） |
| 11 | Play/Pause 可用 | ⏳ TV_PENDING | 播放页已出现「上一首 / 暂停 / 下一首」三键且焦点态正确，**暂停后再继续**待用户实机确认 |
| 12 | 退出播放页不中断 | ⏳ TV_PENDING | 后台 MediaSession 已实现，**返回上级页面后是否继续出声**待用户实机确认 |
| 13 | 凭据无明文泄漏 | ✅ | `flutter_secure_storage` + 仅存 sha256 哈希 + 日志/报告脱敏 + `.gitignore` |
| 14 | 完成 fnos_api_verified.md | ✅ | 9 个 Phase 1 接口全部 **VERIFIED**，IP 已脱敏 |
| 15 | 完成 phase1_test_report.md | ✅ | 即本文件 |

> 结论：**15 项中 13 项已达标** —— 1–3、5–9、13–15 由 CI 与真实 NAS 验证；
> **4、10 已于 2026-10-03 由电视实机验证**（见 §8）。
> 仅剩 **11（暂停后再继续）、12（退出播放页不中断）** 待用户实机确认，
> 二者都是播放控制项，不影响「能启动 / 能登录 / 能播放」这一主干结论。
>
> **「在电视真实播放验证通过之前，不进入 Phase 2」—— 该门槛已于 2026-10-03 满足。**
> 是否进入 Phase 2 由用户决定。

---

## 8. 电视端实测记录（2026-10-03 · 海信 E7N Pro）

用户实机安装 **G = `app-hisense-release.apk`**（构建自 commit `ad2ea97`），结果：

1. **服务器状态页**：显示 NAS 地址与登录用户，绿勾 **可达**
   （HTTP `/initialization/state`），并显示健康检查返回体 `{"initialized": true}`；
2. **播放页**：曲目 / 艺人 · 专辑 / `FLAC · 16bit / 44kHz` / `0:11 / 4:05`，
   进度条与计秒走动；`上一首 / 暂停 / 下一首` 三键齐备且焦点态正确。

由此**一次性排除**了此前怀疑过的全部设备层因素：Flutter 引擎、渲染后端
（Impeller / GLES）、ABI 裁剪、插件 native 注册（含 audio_service 前台服务与
Keystore）、音频解码、MediaSession、时间轴更新。**此后的问题一律属于业务逻辑层。**

> ⚠️ 版本追溯：`ad2ea97` 之后，main 上还有 `1837428`（预检规则 + 排错文档）、
> `04d418f`（`restore()` / `logout()` 的存储超时加固）、`206877e`（修掉一处
> 「假通过」的测试）三个提交，CI 全绿（**137 tests passed**），
> 但**没有重新发布到 `release` 分支** —— 刻意保持发布产物 = 实机上验证过的那个 sha，
> 避免「同一网址背后的产物被悄悄换掉」导致问题难以追溯。
> 需要发布加固版时：`git push --force origin main:publish-diag`。
