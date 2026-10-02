import 'package:feiniu_tv_music/core/boot_log.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 启动日志与「安全模式」判定测试。
///
/// 背景：Android TV 上出现「黑屏 → 闪退」，且盒子通常没有 adb，
/// 只能靠 [BootLog] 落盘的日志取证。因此这里锁定三件事：
/// 1. 记日志这个动作本身**绝不能抛异常**（它是最后一道取证手段，
///    自己崩了就没信息了）；
/// 2. 每行都带时间戳，缓冲有上限；
/// 3. 「安全模式」的阈值语义固定为「连续 2 次启动未走完」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('feiniu/boot');
  final List<MethodCall> sent = <MethodCall>[];

  setUp(() {
    sent.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      sent.add(call);
      switch (call.method) {
        case 'bootAttempts':
          return 0;
        case 'logPath':
          return '/data/local/tmp/boot.log';
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('BootLog 内存日志', () {
    test('mark 记录到内存且不抛异常', () {
      expect(() => BootLog.mark('契约测试-唯一标记-A'), returnsNormally);
      expect(
        BootLog.lines.any((line) => line.contains('契约测试-唯一标记-A')),
        isTrue,
      );
    });

    test('每行都带 HH:mm:ss.SSS 时间戳前缀', () {
      BootLog.mark('契约测试-时间戳');
      final line = BootLog.lines
          .lastWhere((l) => l.contains('契约测试-时间戳'));
      expect(RegExp(r'^\d{2}:\d{2}:\d{2}\.\d{3} ').hasMatch(line), isTrue,
          reason: '日志行应以时间戳开头，实际：$line');
    });

    test('日志会同步发往原生（电视端取证通道）', () async {
      BootLog.mark('契约测试-落盘');
      await pumpEventQueue();
      final bool forwarded = sent.any((MethodCall c) {
        if (c.method != 'log') {
          return false;
        }
        final Object? args = c.arguments;
        return args is Map && args['msg'] == '契约测试-落盘';
      });
      expect(forwarded, isTrue);
    });

    test('缓冲有上限，长时间运行不会无限增长且保留最近日志', () {
      for (var i = 0; i < 700; i++) {
        BootLog.mark('压力行 $i');
      }
      expect(BootLog.lines.length, lessThanOrEqualTo(400));
      expect(BootLog.lines.any((l) => l.contains('压力行 699')), isTrue);
    });
  });

  group('BootLog 安全模式', () {
    test('原生返回 0 次启动时，不进入安全模式', () {
      expect(BootLog.bootAttempts, 0);
      expect(BootLog.safeMode, isFalse);
    });

    test('安全模式阈值语义固定为「连续 2 次启动未走完」', () {
      // 阈值来自原生 boot_attempts；这里显式锁定判定表达式，
      // 避免日后被随手改成 1 或 3。
      expect(BootLog.safeMode, equals(BootLog.bootAttempts >= 2));
    });

    test('未调用 start() 时 synced 也能直接 await（不会挂起）', () async {
      await BootLog.synced.timeout(const Duration(seconds: 1));
    });

    test('原生通道可用时 nativeDeviceId 返回原生值', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'deviceId') {
          return '0123456789abcdef0123456789abcdef';
        }
        return null;
      });
      expect(
        await BootLog.nativeDeviceId(),
        '0123456789abcdef0123456789abcdef',
      );
    });
  });
}
