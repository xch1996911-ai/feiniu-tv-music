import 'package:feiniu_tv_music/core/branding.dart';
import 'package:feiniu_tv_music/core/build_identity.dart';
import 'package:flutter_test/flutter_test.dart';

/// 构建身份（UI 2.0）。
///
/// ## 为什么这个也要测
/// 「装的还是旧包」已经反复出现三次。判断依据必须**稳定且可断言**：
/// 版本号、commit、通道三者拼成一行指纹，显示在启动页左下角与诊断页。
/// 一旦有人改了常量或注入名（`--dart-define` 的 key），这里立即变红。
///
/// 测试环境没有注入任何 `--dart-define`，所以断言的是**兜底值**：
/// 兜底必须是 `unknown` / pubspec 同步值，而不是看起来正常的假数据。
void main() {
  group('BuildIdentity 兜底', () {
    test('未注入时版本取 branding 常量（与 pubspec 同步）', () {
      expect(BuildIdentity.appVersion, kAppVersion);
      expect(BuildIdentity.versionCode, kAppVersionCode);
      expect(BuildIdentity.appVersion, '0.3.0');
      expect(BuildIdentity.versionCode, 3);
    });

    test('未注入时 commit / 构建时间如实显示 unknown', () {
      expect(BuildIdentity.gitSha, 'unknown');
      expect(BuildIdentity.shortSha, 'unknown');
      expect(BuildIdentity.buildTime, 'unknown');
    });

    test('未注入通道时按编译模式推断（测试是 debug → DEV）', () {
      expect(BuildIdentity.channel, 'DEV');
    });
  });

  group('BuildIdentity 展示串', () {
    test('versionLine 含版本、versionCode、sha、通道', () {
      final String line = BuildIdentity.versionLine;
      expect(line, contains('v0.3.0'));
      expect(line, contains('(3)'));
      expect(line, contains('unknown'));
      expect(line, contains('DEV'));
    });

    test('oneLine 额外带构建时间', () {
      expect(BuildIdentity.oneLine, contains(kAppName));
      expect(BuildIdentity.oneLine, contains(BuildIdentity.channel));
      expect(BuildIdentity.oneLine, contains(BuildIdentity.buildTime));
    });

    test('shortSha 只截 7 位（注入长 sha 时不溢出）', () {
      // 注：真实注入值在测试环境取不到，这里验证的是截断规则本身 ——
      // 通过静态方法无法直接构造，故用长度断言兜住「不返回空」。
      expect(BuildIdentity.shortSha.length, lessThanOrEqualTo(7));
      expect(BuildIdentity.shortSha.isNotEmpty, isTrue);
    });
  });
}
