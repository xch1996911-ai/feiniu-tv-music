import 'package:flutter/foundation.dart';

import 'branding.dart';

/// 构建身份 —— 「装上的是不是这一版」的唯一凭据。
///
/// ## 为什么需要它
///
/// 项目里反复出现「装的还是旧界面」：包已经换了、服务器哈希也核对过，
/// 但电视上看到的是旧进程 / 旧包。只靠「界面长什么样」判断版本不可靠 ——
/// 必须有一个能一眼读出来、且**随构建变化**的指纹。
///
/// ## 数据从哪来
///
/// 全部通过 `--dart-define` 在**构建时**注入，运行时不读文件、不请求网络：
///
/// ```sh
/// flutter build apk --release \
///   --dart-define=APP_VERSION=0.3.0 \
///   --dart-define=APP_VERSION_CODE=3 \
///   --dart-define=BUILD_SHA=$(git rev-parse --short=7 HEAD) \
///   --dart-define=BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
///   --dart-define=BUILD_CHANNEL=DEV1
/// ```
///
/// 缺省值刻意写成 `unknown` 而不是猜一个值：没有注入就是没有注入，
/// 如实显示比显示一个看起来正常的假版本更有用。
class BuildIdentity {
  const BuildIdentity._();

  /// 版本名（`pubspec.yaml` 里 `+` 之前的部分）。
  static const String appVersion = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: kAppVersion,
  );

  /// versionCode（`pubspec.yaml` 里 `+` 之后的部分）。
  static const int versionCode = int.fromEnvironment(
    'APP_VERSION_CODE',
    defaultValue: kAppVersionCode,
  );

  /// 构建所用 commit（完整或短 sha 均可）。
  static const String gitSha = String.fromEnvironment(
    'BUILD_SHA',
    defaultValue: 'unknown',
  );

  /// 构建时间（ISO-8601，UTC）。
  static const String buildTime = String.fromEnvironment(
    'BUILD_TIME',
    defaultValue: 'unknown',
  );

  /// 构建通道：DEV1 / DEV / CI / RELEASE …
  static const String buildChannel = String.fromEnvironment(
    'BUILD_CHANNEL',
    defaultValue: '',
  );

  /// 通道显示值。没注入时按编译模式推断（release → RELEASE，否则 DEV）。
  static String get channel =>
      buildChannel.isNotEmpty ? buildChannel : (kReleaseMode ? 'RELEASE' : 'DEV');

  /// 短 sha（7 位）。`unknown` 原样返回。
  static String get shortSha {
    if (gitSha == 'unknown' || gitSha.isEmpty) return 'unknown';
    return gitSha.length <= 7 ? gitSha : gitSha.substring(0, 7);
  }

  /// 单行指纹，用于启动页角落与诊断页。
  static String get oneLine =>
      '$kAppName $channel · v$appVersion+$versionCode · $shortSha · $buildTime';

  /// 版本号一行（不含构建时间），用于空间紧张处。
  static String get versionLine =>
      'v$appVersion ($versionCode) · $shortSha · $channel';
}
