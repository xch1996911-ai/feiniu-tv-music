# 飞牛 fnOS 音乐 API 验证文档（fnos_api_verified.md）

> 阶段：Phase 1
> 生成日期：2026-10-02
> 关联：[technical_research.md](../technical_research.md) §2、[tools/fnos_api_probe](../tools/fnos_api_probe)

## 0. 重要声明（务必先读）

**本沙箱环境没有真实飞牛 NAS，也没有可联网的构建工具链**，因此本文件中的接口**尚未用真实设备跑通**。

- 所有接口当前状态均为 **UNVERIFIED（研究整理，待真机 probe 验证）**，来自 Phase 0 对第三方逆向资料与开源增强服务公开文档的事实整理，**不是本项目推测**。
- 真实验证必须由 `tools/fnos_api_probe` 在你自己的真机/真 NAS 上运行后产出 `VERIFIED` / `FAILED`，并回填本文件。
- 严禁把推测写成 `VERIFIED`。
- 认证机制（Cookie vs authx）必须在真机判定，见 §3。

## 1. 探针使用方法

```bash
cd tools/fnos_api_probe
dart pub get
dart run bin/probe.dart --host http://<NAS局域网IP>:5666 --username <账号> --password <密码>
# 若用自签 HTTPS：
# dart run bin/probe.dart --host https://<NAS>:5667 --username <账号> --password <密码> --insecure
```

探针会：
1. 探测 `initialization/state`（无认证）
2. `password-login`（sha256 密码）
3. 判定认证机制：分别用「仅 Cookie」与「仅 X-Music-API 头」请求 `user/me`
4. `user/me`、曲目/专辑/歌手列表、`lyric/list`、`track/stream`（Range 探测）
5. 输出脱敏报告到 `.probe_results/`（已被 `.gitignore` 忽略，不进 Git）

## 2. 接口验证表

> 状态图例：**VERIFIED** = 真机验证通过；**UNVERIFIED** = 仅研究整理，待 probe；**FAILED** = 真机验证失败。

| # | 接口 | 方法 | 路径 | 来源 | 状态 | 备注（研究整理） |
|---|---|---|---|---|---|---|
| 1 | 连接探测 | GET | `/music/api/v1/initialization/state` | 逆向博客 | UNVERIFIED | 登录页判断可达；Phase 1 也用作链路探测。返回 `{code,msg,data}` |
| 2 | 密码登录 | POST | `/music/api/v1/user/password-login` | 逆向博客 | UNVERIFIED | body `{username, password: sha256(明文)}`；成功返回 `data.userToken` + `data.user` |
| 3 | 当前用户 | GET | `/music/api/v1/user/me` | 逆向博客 | UNVERIFIED | 需认证；用于补全用户信息 |
| 4 | 曲目列表 | GET | `/music/api/v1/track/list` | 逆向博客 | UNVERIFIED | 分页 `page`/`size`；返回 `{list,total}` |
| 5 | 专辑列表 | GET | `/music/api/v1/album/list` | 逆向博客 | UNVERIFIED | 同分页结构 |
| 6 | 歌手列表 | GET | `/music/api/v1/artist/list` | 逆向博客 | UNVERIFIED | 同分页结构 |
| 7 | 歌词列表 | GET | `/music/api/v1/lyric/list` | 逆向博客 | UNVERIFIED | 参数 `guid`；返回 LRC 文本（含翻译行）。逐字歌词是否存在待确认 |
| 8 | 音频流 | GET | `/music/api/v1/track/stream?guid=` | 逆向博客 | UNVERIFIED | 支持 `Range` 分段；认证必需（经请求头，不在 URL 暴露 token） |
| 9 | 封面 | GET | `/music/api/v1/static/cover?coverId=&size=800` | 逆向博客 | UNVERIFIED | 统一 `size=800` 以便共享缓存；认证要求同音频流 |

**通用信封**：`{ "code": 0, "msg": "", "data": {...} }`；`code == 0` 成功；**`code == 120001` = token 失效**（触发重登录）。

## 3. 认证机制（必须在真机判定，不得假定）

飞牛存在两套认证方案，App 与 Web 可能不同：

| 方案 | 描述 | 当前状态 |
|---|---|---|
| A. Cookie | 请求头 `Cookie: music-token=<token>` | 待 probe 判定（FeiNiuMusic 源码行为指向此方案） |
| B. 签名头 | `X-Music-API: v1` + `authx` 哈希签名头 | 待 probe 判定（Web 端方案；app 接口是否必需未知） |
| C. 二者并存 | 不同接口分别要求 | 待 probe 判定 |

**判定方法**：见 §1 探针步骤 3。若「仅 Cookie」可认证而「仅头」失败 → 采用方案 A（本 App 当前默认实现）。若需要 `authx` 签名（Go `url.Values.Encode()` 规范化的 URL-decode 后 query 签名，POST 签 JSON 原文），则需在 `FnosClient` 中补充签名逻辑并回填本文件。

## 4. 数据模型字段（Phase 1 实际采用）

严格只取验证字段（需求 §6），未知字段忽略：

- **Track**: `guid, title, coverId, duration(ms), album{guid,name,coverId}, artists[{guid,name,coverId}], audioSpec{format,sampleRate,bitDepth,bitrate}, hasLyric, accessStatus`
- **Album**: `guid, name, coverId, trackCount`
- **Artist**: `guid, name, coverId, trackCount, albumCount`
- `accessStatus == 3` → 音频文件失效（不可播）

> `duration` 单位假设为 **毫秒**（来自逆向资料）；若真机返回秒，需在 `Track.fromJson` 修正。此项列为待 probe 确认。

## 5. 已知风险 / 待真机确认项（来源：technical_research.md §10）

| # | 风险 | 验证方式 |
|---|---|---|
| 1 | 认证机制二选一（Cookie vs authx） | §1 探针步骤 3 |
| 2 | 分页参数名（page/size）与排序枚举 | 真机请求验证 |
| 3 | 收藏/歌单写接口（Phase 1 暂不涉及） | 后续阶段抓包 |
| 4 | `duration` 单位（ms vs s） | 真机观察 |
| 5 | 逐字歌词是否存在于原生服务 | `/lyric/list` 真机观察 |
| 6 | 自签 HTTPS 在 TV 设备的证书豁免差异 | 真机（小米电视/盒子优先） |
| 7 | `flutter_secure_storage` 在国产盒子的可用性 | 真机测试 |
| 8 | 飞牛固件更新可能变更 API | `initialization/state` 版本探测 |
| 9 | 部分接口路径是否随版本变化 | 真机 probe |
| 10 | 音频流是否对无 Range 的请求正常返回 | 真机 probe |

## 6. 回填规范

运行 probe 后，将 §2 表格中对应接口的「状态」改为 `VERIFIED` 或 `FAILED`，并在「备注」追加真实观察到的：HTTP 状态码、响应耗时、实际字段名、异常信息。同时更新 §3 认证机制结论。
