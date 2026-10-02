# FeiNiu TV Music — 飞牛 fnOS NAS 专用 Android TV 音乐播放器

> 专为「飞牛 NAS + 客厅电视」设计的遥控器优先（D-pad First）音乐播放器。
> Phase 1 目标：**验证并跑通最基础的播放闭环**——TV / Flutter → 局域网飞牛 NAS → 登录飞牛音乐 → 读取歌曲/专辑/歌手 → 选曲 → 成功播放并听到声音。

## 当前阶段状态（Phase 1）

| 项 | 状态 |
|---|---|
| 工程脚手架 | ✅ 完成 |
| 分层架构（Provider / Repository / Domain） | ✅ 完成 |
| `MusicServerProvider` 抽象 + `FnosProvider` 实现 | ✅ 完成 |
| `FnosClient`（HTTP / Cookie / sha256 登录 / 120001 处理） | ✅ 完成 |
| 登录 / 读库 / 播放闭环 | ✅ 代码完成 |
| `just_audio` + `audio_service` MediaSession | ✅ 代码完成 |
| 真实 NAS API 验证（probe） | ⛔ `BLOCKED_BY_REAL_NAS_TEST`（沙箱无真实 NAS） |
| `flutter analyze` / `flutter test` / APK 构建 | ⛔ `BLOCKED_BY_ENVIRONMENT`（沙箱无 pub.dev / Android SDK） |

> 详见 [`docs/fnos_api_verified.md`](docs/fnos_api_verified.md) 与 [`docs/phase1_test_report.md`](docs/phase1_test_report.md)。

## 快速开始（在具备完整 Flutter 工具链的机器上）

```bash
flutter pub get
flutter analyze          # 期望无 error
flutter test             # 运行单元/模型解析测试
flutter build apk        # 产出 Debug/Release APK

# 真机 API 验证（连真实飞牛 NAS，不需要先编译 App）
cd tools/fnos_api_probe
dart pub get
dart run bin/probe.dart --host http://192.168.1.10:5666 --username <你的账号> --password <你的密码>
```

## 架构（Phase 1 最小分层）

```
UI (pages)  ──▶  Repositories  ──▶  MusicServerProvider(接口)
                                      └─ FnosProvider ──▶ FnosClient(HTTP)
                                      
Playback: PlaybackRepository ──▶ AudioHandler(just_audio + audio_service)
凭据:    SecureStore(flutter_secure_storage, 密码仅存 sha256 hash)
```

依赖规则：`ui → repositories → servers(fnos)`；UI 不直接 import `servers/fnos/*`；未来 Subsonic/Jellyfin 只需新增 Provider 实现，不改接口。

## 安全约定

- Token 始终存于 `flutter_secure_storage`（Android Keystore）。
- 密码**默认不保存**；仅当用户主动开启「记住密码并自动重新登录」时，才把 **sha256 哈希**（非明文）存入 Keystore，用于 token 失效后自动重登。
- 局域网自签 HTTPS 证书豁免**仅限用户明确配置的主机/IP**，绝不全局关闭 TLS 校验。
- 所有日志对用户名/密码/Token **强制脱敏**。

## 许可证

本项目从零实现，计划以 Apache-2.0 开源（待确认）。参考仓库 FeiNiuMusic / NagoMusic 均**无 LICENSE**（默认版权保留），本项目不复制其任何源码，仅参考公开 API 协议事实。详见 `technical_research.md`。
