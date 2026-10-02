import 'package:feiniu_tv_music/main_engine_smoke.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 引擎冒烟入口（`lib/main_engine_smoke.dart`）的回归测试。
///
/// 这个入口的唯一用途是「把 Flutter 引擎/渲染从业务代码与插件里剥离出来」，
/// 所以测试只锁两件事：
/// 1. 它能在**没有任何插件**的环境下画出第一帧
///    （不依赖 audio_service / just_audio / flutter_secure_storage / 网络）；
/// 2. 它会把 `first frame callback` 这类关键节点发给原生 ——
///    电视上没有 adb，这些落盘痕迹就是唯一判据。
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

  testWidgets('first frame callback 会同步给原生（电视端唯一判据）',
      (WidgetTester tester) async {
    await tester.pumpWidget(const EngineSmokeApp(maxFrames: 2));
    await tester.pump();
    await pumpEventQueue();

    expect(
      logged.any((String m) => m.contains('first frame callback')),
      isTrue,
      reason: '实际收到的日志：$logged',
    );
  });

  test('DIAG_TAG 有默认值，未注入 dart-define 时也不会是空串', () {
    expect(kDiagTag, isNotEmpty);
  });
}
