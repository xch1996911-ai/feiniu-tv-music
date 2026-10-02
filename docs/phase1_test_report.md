# Phase 1 测试报告（phase1_test_report.md）

> 阶段：Phase 1 — 基础播放闭环
> 报告日期：2026-10-02
> 关联：[technical_research.md](../technical_research.md)、[fnos_api_verified.md](./fnos_api_verified.md)

## 0. 关于本报告真实性的说明

本报告**不伪造任何测试结果**。

- 本开发沙箱**没有真实飞牛 NAS**，无法执行真实 API 验证、播放验证、遥控验证。
- 本沙箱**无法访问 pub.dev / dl.google.com / maven.google.com**，且**未安装 Android SDK**，因此无法执行 `flutter pub get` / `flutter analyze` / `flutter test` / `flutter build apk`。
- 凡因上述环境限制无法执行的项，一律标注：
  - `BLOCKED_BY_REAL_NAS_TEST` —— 需要真实 NAS（含设备）才能验证；
  - `BLOCKED_BY_ENVIRONMENT` —— 需要完整 Flutter/Android 工具链与网络才能验证。
- 代码本身已按 Phase 1 范围完整实现，并在文末给出用户在本机验证所需的确切命令。

---

## 1. 环境信息

| 项 | 沙箱值 | 备注 |
|---|---|---|
| Flutter 版本（沙箱） | 3.0.0 | 内置 Dart 2.17.0，**低于项目下限 3.0.0**；仅为沙箱环境，用户本机建议 Flutter ≥ 3.10 / Dart ≥ 3.0 |
| Dart SDK（目标） | ≥ 3.2 | 见 `pubspec.yaml` environment |
| Android SDK | **未安装** | `ANDROID_HOME` 未设置，无 `android.jar` → `BLOCKED_BY_ENVIRONMENT` |
| pub.dev 可达性 | **不可达** | 无法 `flutter pub get` → `BLOCKED_BY_ENVIRONMENT` |
| fnOS 版本 | 未知 | 用户真实环境决定，待回填 |
| 飞牛音乐版本 | 未知 | 用户真实环境决定，待回填 |
| NAS 连接方式 | 未知 | 用户真实环境决定，待回填 |
| HTTP / HTTPS | 默认 **HTTP 5666** 局域网 | HTTPS 5667 为自签证书；V1 优先局域网 HTTP 以减少证书问题 |
| 实际认证模式 | **UNVERIFIED** | 待 `tools/fnos_api_probe` 真机判定（见 fnos_api_verified.md §3） |

---

## 2. 构建 / 分析 / 测试（全部 BLOCKED_BY_ENVIRONMENT）

| 检查 | 沙箱结果 | 用户本机命令 |
|---|---|---|
| `flutter pub get` | ⛔ 无法执行（沙箱 Dart 2.17.0 低于项目下限 3.0.0，且无法访问 pub.dev） | `flutter pub get` |
| `flutter analyze` 无 error | ⛔ 无法执行 | `flutter analyze` |
| `flutter test` 通过 | ⛔ 无法执行 | `flutter test`（已编写 5 个不依赖 NAS 的单测） |
| `flutter build apk` | ⛔ 无法执行（无 Android SDK/Gradle/依赖） | `flutter build apk --debug` / `--release` |
| Android TV / 模拟器启动 | ⛔ 无法执行 | `flutter run` 选择 TV 设备或 AVD (TV) |

> 已编写的单元测试（`test/`）：模型解析、sha256 密码哈希、Result 代数、分页 hasMore、URL 构造。这些**不依赖真实 NAS**，可在具备工具链的机器上直接运行。

---

## 3. 真实 NAS 验证（全部 BLOCKED_BY_REAL_NAS_TEST）

| 项目 | 状态 | 说明 |
|---|---|---|
| 连接真实飞牛 NAS | ⛔ BLOCKED_BY_REAL_NAS_TEST | 需要用户局域网中的真实 NAS |
| 登录（密码 sha256） | ⛔ BLOCKED_BY_REAL_NAS_TEST | 待 probe 真机验证 |
| 读取歌曲列表 | ⛔ BLOCKED_BY_REAL_NAS_TEST | 待 probe |
| 读取专辑列表 | ⛔ BLOCKED_BY_REAL_NAS_TEST | 待 probe |
| 读取歌手列表 | ⛔ BLOCKED_BY_REAL_NAS_TEST | 待 probe |
| 选择并播放真实 NAS 音乐 | ⛔ BLOCKED_BY_REAL_NAS_TEST | 需真机 + 真曲 |
| 播放成功格式 | ⛔ BLOCKED_BY_REAL_NAS_TEST | MP3 / FLAC / AAC 待真机确认 |
| 播放失败格式 | ⛔ BLOCKED_BY_REAL_NAS_TEST | FLAC/DSF 若失败不立即引入 FFmpeg（留 Phase 3） |
| 平均 API 响应时间 | ⛔ BLOCKED_BY_REAL_NAS_TEST | 待 probe 计时 |
| 首曲播放启动时间 | ⛔ BLOCKED_BY_REAL_NAS_TEST | 待真机测量 |
| 遥控 Play/Pause | ⛔ BLOCKED_BY_REAL_NAS_TEST | MediaSession 已接，真机验证 |
| 退出播放页不中断 | ⛔ BLOCKED_BY_REAL_NAS_TEST | 后台 MediaSession 已实现，真机验证 |

---

## 4. 已验证 / 已落实（代码层面，非运行层面）

以下为**代码已正确实现**的项（逻辑层面，待运行验证）：

- 分层架构：`servers(MusicServerProvider + FnosProvider + FnosClient)` → `repositories` → `ui`，UI 不直接 import `servers/fnos/*`。
- `MusicServerProvider` 抽象接口仅定义 Phase 1 实际使用的最小方法集。
- 登录 sha256 密码哈希，明文不离开本机；token 存 `flutter_secure_storage`。
- 密码默认不保存；开启「记住密码」时仅保存 **sha256 哈希**（非明文）。
- `code == 120001` token 失效统一处理：有哈希则自动重登，否则回登录页。
- 局域网自签证书豁免**仅限用户显式配置的主机**（`trustedHosts`），未全局关闭 TLS。
- 播放引擎 `just_audio`（ExoPlayer 系统解码优先），未引入 media_kit（留 Phase 3）。
- `audio_service` MediaSession：后台播放 + 遥控媒体键（传输键由系统路由，Flutter 不重复接管）。
- 临时 TV 验证 UI：登录 → 服务器状态 → 歌曲列表 → 播放页，基本 D-pad 焦点（列表行可聚焦、OK 选曲、返回键路由）。
- 安全红线：`.gitignore` 已排除凭据/Token/FNID/本地 probe 结果；所有日志强制脱敏（`Log.redactUser` / `redactHost`，Token 仅显示前 6 位）。

---

## 5. 发现的问题 / 疑点

1. **duration 单位假设**：模型假设 `duration` 为毫秒；若真机返回秒需修正（fnos_api_verified.md §5）。
2. **认证机制未定**：Cookie vs authx 签名头未真机判定，App 当前默认 Cookie 方案。
3. **Phase 0 参考仓库无 LICENSE**：已遵守合规要求，**未复制任何参考源码**，全部自研；API 协议事实来自第三方公开逆向与开源增强服务文档。
4. **沙箱无法本地验证**：编译/分析/测试/构建需用户在本机具备完整工具链后执行。
5. **原生工程文件未实机验证**：`android/` 下清单/构建脚本/图标为按 Flutter 3.16 标准手写的；若与用户 Flutter 版本不符，可在项目根执行 `flutter create .` 重新生成原生工程（不会删除 `lib/` 与 `pubspec` 内容）。

---

## 6. 下一步建议（进入 Phase 2 前）

1. **用户在本机执行**（具备 Flutter ≥ 3.16 + Android SDK）：
   ```bash
   flutter pub get
   flutter analyze        # 期望无 error
   flutter test           # 运行单元/模型解析测试
   flutter build apk --debug
   ```
2. **准备一台真实飞牛 NAS + Android TV/模拟器**，运行 `tools/fnos_api_probe` 完成 API 真机验证，回填 `fnos_api_verified.md`。
3. 用真机跑通：登录 → 列表 → 选曲 → 播放；确认 MP3/FLAC/AAC 播放与遥控键。
4. 回填本节 §1 的 fnOS/飞牛音乐版本、连接方式、响应时间、首播启动时间。
5. 仅当**全部 15 项验收标准**（见 §7）满足后，再进入 Phase 2（真正的 TV 首页 / D-pad Focus 系统 / 专辑页 / 歌手页）。

---

## 7. 验收标准对照（Phase 1 通过条件）

| # | 验收项 | 状态 | 说明 |
|---|---|---|---|
| 1 | Flutter 工程正常编译 | ⛔ BLOCKED_BY_ENVIRONMENT | 用户本机需 `flutter pub get` + `flutter build` |
| 2 | `flutter analyze` 无 error | ⛔ BLOCKED_BY_ENVIRONMENT | 用户本机执行 |
| 3 | `flutter test` 通过 | ⛔ BLOCKED_BY_ENVIRONMENT | 单测已编写，待运行 |
| 4 | Android TV / 模拟设备可启动 | ⛔ BLOCKED_BY_ENVIRONMENT | 用户本机 `flutter run` |
| 5 | 连接真实飞牛 NAS | ⛔ BLOCKED_BY_REAL_NAS_TEST | 需真实 NAS |
| 6 | 可以登录 | ⛔ BLOCKED_BY_REAL_NAS_TEST | 待 probe + 真机 |
| 7 | 读取歌曲列表 | ⛔ BLOCKED_BY_REAL_NAS_TEST | 待真机 |
| 8 | 读取专辑列表 | ⛔ BLOCKED_BY_REAL_NAS_TEST | 待真机 |
| 9 | 读取歌手列表 | ⛔ BLOCKED_BY_REAL_NAS_TEST | 待真机 |
| 10 | 选择真实 NAS 音乐并播放 | ⛔ BLOCKED_BY_REAL_NAS_TEST | 待真机 |
| 11 | Play/Pause 可用 | ⛔ BLOCKED_BY_REAL_NAS_TEST | MediaSession 已接，待真机 |
| 12 | 退出播放页不中断 | ⛔ BLOCKED_BY_REAL_NAS_TEST | 后台 MediaSession，待真机 |
| 13 | 凭据无明文泄漏 | ✅ 代码层面已落实 | `flutter_secure_storage` + 仅存哈希 + 日志脱敏 + `.gitignore` |
| 14 | 完成 fnos_api_verified.md | ✅ 已生成（研究整理版） | 待真机 probe 回填 VERIFIED/FAILED |
| 15 | 完成 phase1_test_report.md | ✅ 已生成 | 即本文件 |

> 结论：**第 13–15 项已落实；第 1–4 项受沙箱工具链限制 BLOCKED_BY_ENVIRONMENT；第 5–12 项受无真实 NAS 限制 BLOCKED_BY_REAL_NAS_TEST。** 未达标项均非代码缺失，而是环境/设备缺失，需在用户本机与真实 NAS 上完成验证后方可进入 Phase 2。
