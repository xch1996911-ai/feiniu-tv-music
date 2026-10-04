import 'package:feiniu_tv_music/domain/album.dart';
import 'package:feiniu_tv_music/domain/artist.dart';
import 'package:feiniu_tv_music/domain/track.dart';
import 'package:feiniu_tv_music/repositories/playback_repository.dart';
import 'package:feiniu_tv_music/services/app_exit.dart';
import 'package:feiniu_tv_music/ui/widgets/exit_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_music_repository.dart';
import 'support/fake_playback_engine.dart';

/// 「返回桌面时选择继续后台播放或退出并停止」的回归。
///
/// ## 本文件覆盖的三层
///
/// 1. **弹窗层**（`TvExitDialog`）：三个选项、默认焦点在「取消」、
///    选择经 `Navigator.pop` 正确回传；
/// 2. **通道层**（`AppExit`）：确实向 `feiniu/boot` 发出
///    `moveTaskToBack` / `exitApp` 两个方法调用；
/// 3. **播放层**（`PlaybackRepository.stopSession`）：委托到引擎，
///    音源停止 —— 真机上的「媒体通知消失 / 前台服务结束」由
///    `PlaybackHandler.stopSession()` 广播 `processingState: idle`
///    驱动（audio_service 0.18 的默认 stop 是空操作，见引擎注释），
///    这一段只能 CI 编译 + 真机核验，纯 Dart 测不了。
void main() {
  group('弹窗层：TvExitDialog', () {
    Future<AppExitChoice?> open(WidgetTester tester) async {
      AppExitChoice? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => Center(
                child: TextButton(
                  onPressed: () async {
                    result = await TvExitDialog.show(ctx);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // 把结果带出去（闭包变量在 dialog pop 后被赋值）
      tester.binding.scheduleForcedFrame();
      return result;
    }

    testWidgets('三个选项齐全，文案与语义一致', (WidgetTester tester) async {
      await open(tester);
      expect(find.text('后台继续播放'), findsOneWidget);
      expect(find.text('退出并停止播放'), findsOneWidget);
      expect(find.text('取消 / 留在应用'), findsOneWidget);
      // 副标题说明各自后果（遥控器用户只看得到文字）
      expect(find.textContaining('歌曲继续播'), findsOneWidget);
      expect(find.textContaining('停止音频并关闭应用'), findsOneWidget);
    });

    testWidgets('默认焦点落在「取消 / 留在应用」（破坏性动作不能一按 OK 就执行）',
        (WidgetTester tester) async {
      await open(tester);
      final FocusNode? focused = FocusManager.instance.primaryFocus;
      expect(focused?.debugLabel, 'exit.cancel',
          reason: '默认焦点必须是取消项，防遥控器误触退出');
    });

    testWidgets('OK 在默认焦点上 = 取消，弹窗关闭', (WidgetTester tester) async {
      AppExitChoice? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => Center(
                child: TextButton(
                  onPressed: () async {
                    result = await TvExitDialog.show(ctx);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.text('后台继续播放'), findsNothing, reason: '弹窗应当已关闭');
      expect(result, AppExitChoice.cancel,
          reason: '默认焦点在取消上，按 OK 必须等于「留在应用」');
    });

    testWidgets('方向键 ↑/↓ 在三项间串联；选中「后台继续播放」回传 background',
        (WidgetTester tester) async {
      AppExitChoice? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => Center(
                child: TextButton(
                  onPressed: () async {
                    result = await TvExitDialog.show(ctx);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // 取消 →（↓ 回绕到第一项）后台继续
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'exit.background',
          reason: '取消 ↓ 应回绕到第一项「后台继续播放」');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(result, AppExitChoice.background);
      expect(find.text('退出并停止播放'), findsNothing, reason: '选择后弹窗应关闭');
    });
  });

  group('通道层：AppExit', () {
    testWidgets('moveToBackground / exitApp 发出正确的通道方法名',
        (WidgetTester tester) async {
      final List<String> calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('feiniu/boot'),
        (MethodCall call) async {
          calls.add(call.method);
          return null;
        },
      );
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('feiniu/boot'), null));

      await AppExit.moveToBackground();
      await AppExit.exitApp();

      // ⚠️ 通道上还会夹杂别的调用（`BootLog.mark` 走同一通道发 'log'），
      //    所以不能断言「完整序列相等」，只断言**这两个动作按序出现**。
      final List<String> relevant = calls
          .where((String c) => c == 'moveTaskToBack' || c == 'exitApp')
          .toList();
      expect(relevant, <String>['moveTaskToBack', 'exitApp'],
          reason: '两个动作必须走约定的通道方法名（与 MainActivity.kt 对齐）');
    });
  });

  group('播放层：stopSession', () {
    test('PlaybackRepository.stopSession 委托给引擎，音源停止', () async {
      final FakeMusicRepository music = FakeMusicRepository();
      final FakePlaybackEngine engine = FakePlaybackEngine();
      final PlaybackRepository repo = PlaybackRepository(
        music: music,
        handler: engine,
      );
      addTearDown(repo.dispose);
      addTearDown(engine.close);

      const Track t = Track(
        guid: 'g1',
        title: '歌',
        durationMs: 60000,
        album: AlbumRef(guid: 'al', name: '专辑'),
        artists: <ArtistRef>[ArtistRef(guid: 'ar', name: '歌手')],
        audioSpec: AudioSpec(format: 'flac'),
      );
      repo.setQueue(<Track>[t], startIndex: 0);
      await repo.pendingLoads;
      expect(engine.playing, isTrue, reason: '前置：队列建立后应处于播放态');

      await repo.stopSession();

      expect(engine.stopSessionCalls, 1,
          reason: '必须走 stopSession（含 MediaSession idle 广播），而不是普通 stop');
      expect(engine.stopCalls, 1, reason: '音源应当已停止');
      expect(engine.playing, isFalse);
    });
  });
}
