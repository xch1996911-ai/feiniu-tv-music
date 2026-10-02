import 'package:feiniu_tv_music/main_engine_smoke.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 引擎冒烟入口（`lib/main_engine_smoke.dart`）的回归测试。
///
/// 这个入口的唯一用途是「把 Flutter 引擎/渲染从业务代码与插件里剥离出来」，
/// 所以测试只锁三件事：
/// 1. 它能在**没有任何插件**的环境下画出第一帧
///    （不依赖 audio_service / just_audio / flutter_secure_storage / 网络）；
/// 2. 首帧等关键节点会被标记出来 —— 电视上没有 adb，这些落盘痕迹就是唯一判据；
/// 3. 标记确实走 `feiniu/boot` 通道发得出去。
///
/// ⚠️ 不要在 `testWidgets` 里 await `pumpEventQueue()` 或 `Future.delayed`。
///    `testWidgets` 体运行在假时钟下，假时钟只由 `pump()` 推进，等 `Future.delayed`
///    会**死等到 10 分钟超时**（不是快速失败），足以让整条流水线在构建前就终止。
///    需要断言异步结果时，用下面的同步旁路 `debugMarkObserver`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('feiniu/boot');
  final List<String> logged = <String>[];

  setUp(() {
    logged.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'log') {
        final Object? args = call.arguments;
        if (args is Map) {
          final Object? msg = args['msg'];
          if (msg is String) {
            logged.add(msg);
          }
        }
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('不依赖任何插件即可渲染出 FLUTTER ENGINE OK',
      (WidgetTester tester) async {
    await tester.pumpWidget(const EngineSmokeApp(maxFrames: 1));
    expect(find.text('FLUTTER ENGINE OK'), findsOneWidget);
  });

  testWidgets('帧计数随首帧回调递增，并在 maxFrames 处停止',
      (WidgetTester tester) async {
    await tester.pumpWidget(const EngineSmokeApp(maxFrames: 3));
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
    expect(find.textContaining('已渲染 3 帧'), findsOneWidget);

    await tester.pump();
    expect(
      find.textContaining('已渲染 3 帧'),
      findsOneWidget,
      reason: '到达 maxFrames 后必须停止刷帧，否则会一直重绘并刷爆日志',
    );
  });

  testWidgets('first frame callback 一定会被标记出来（电视端唯一判据）',
      (WidgetTester tester) async {
    final List<String> seen = <String>[];
    debugMarkObserver = seen.add;
    addTearDown(() {
      debugMarkObserver = null;
    });

    await tester.pumpWidget(const EngineSmokeApp(maxFrames: 2));
    await tester.pump();

    expect(
      seen,
      contains('first frame callback'),
      reason: '实际标记到的节点：$seen',
    );
  });

  test('标记会经 feiniu/boot 通道发得出去（原生落盘通道必须可用）', () async {
    // plain test() 里是真实时钟，await 正常；再加 5 秒超时兜底，
    // 万一通道回执不来也只是快速失败，不会像假时钟那样空等 10 分钟。
    await smokeMarkForTest('probe-from-test')
        .timeout(const Duration(seconds: 5));
    expect(logged, contains('[smoke] probe-from-test'));
  });

  test('DIAG_TAG 有默认值，未注入 dart-define 时也不会是空串', () {
    expect(kDiagTag, isNotEmpty);
  });
}
