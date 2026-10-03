import 'package:feiniu_tv_music/app/theme.dart';
import 'package:feiniu_tv_music/domain/track.dart';
import 'package:feiniu_tv_music/repositories/music_repository.dart';
import 'package:feiniu_tv_music/repositories/playback_repository.dart';
import 'package:feiniu_tv_music/ui/widgets/mini_player.dart';
import 'package:feiniu_tv_music/ui/widgets/tv_glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_music_repository.dart';
import 'support/fake_playback_engine.dart';

/// 首页底部**迷你播放器**的焦点顺序与行为（对应 V4 验收「六、4」）。
///
/// 需求原文要求：
/// - 默认焦点落在**左侧专辑封面**上（不是歌曲文字）；
/// - 焦点顺序 `封面 → 上一首 → 播放/暂停 → 下一首 → 播放队列`；
/// - 封面按 OK = 打开完整播放页；
/// - 歌曲名 / 歌手只展示、**不抢占焦点**。
///
/// 这些全部是焦点树层面的事，只有 widget 测试抓得到。
/// 五个节点由调用方（真实 App 里是 `AppShell`）持有并释放。
///
/// 之所以要外部持有：关闭全屏播放页后要把焦点**恢复**到底部播放条上，
/// 而只有 Shell 知道「播放页刚被关掉」。
///
/// ⚠️ 每个用例单独建一套：`FocusNode` 一旦 `dispose` 就不能再用，
/// 若在 `main()` 顶层只建一次，第二个用例就会拿到已释放的节点。
class _MiniNodes {
  final FocusNode cover = FocusNode(debugLabel: 'mini.cover');
  final FocusNode prev = FocusNode(debugLabel: 'mini.prev');
  final FocusNode play = FocusNode(debugLabel: 'mini.play');
  final FocusNode next = FocusNode(debugLabel: 'mini.next');
  final FocusNode queue = FocusNode(debugLabel: 'mini.queue');

  void dispose() {
    cover.dispose();
    prev.dispose();
    play.dispose();
    next.dispose();
    queue.dispose();
  }
}

void main() {
  late FakeMusicRepository music;
  late FakePlaybackEngine engine;
  late PlaybackRepository playback;
  late _MiniNodes nodes;

  var openPlayerCalls = 0;
  var openQueueCalls = 0;

  setUp(() {
    music = FakeMusicRepository();
    engine = FakePlaybackEngine();
    playback = PlaybackRepository(music: music, handler: engine);
    nodes = _MiniNodes();
    openPlayerCalls = 0;
    openQueueCalls = 0;
  });

  tearDown(() async {
    nodes.dispose();
    playback.dispose();
    await engine.close();
  });

  String? focusedLabel() => FocusManager.instance.primaryFocus?.debugLabel;

  Future<void> ready(WidgetTester tester) async {
    music.catalogue = <Track>[for (int i = 0; i < 3; i++) makeTrack('g$i')];
    await tester.runAsync(() async {
      playback.setQueue(music.catalogue, startIndex: 1);
      await playback.pendingLoads;
    });
  }

  Future<void> pumpMini(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaybackRepository>.value(value: playback),
          ChangeNotifierProvider<MusicRepository>.value(value: music),
        ],
        child: MaterialApp(
          theme: buildTvTheme(),
          home: Scaffold(
            // 与真实 Shell 一样放在 Column 里（这样宽度是受约束的，
            // Row 里的 Expanded 才不会因为无界宽度而报错）。
            body: Column(
              children: <Widget>[
                const Spacer(),
                MiniPlayer(
                  onOpenPlayer: () => openPlayerCalls++,
                  onOpenQueue: () => openQueueCalls++,
                  coverNode: nodes.cover,
                  prevNode: nodes.prev,
                  playNode: nodes.play,
                  nextNode: nodes.next,
                  queueNode: nodes.queue,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> tearDownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  /// 真实 App 里初始焦点由 Shell 给（这里显式聚焦封面，等价于「默认落在封面」）。
  Future<void> focusCover(WidgetTester tester) async {
    nodes.cover.requestFocus();
    await tester.pump();
    expect(focusedLabel(), 'mini.cover');
  }

  group('焦点顺序（需求指定的五段链）', () {
    testWidgets('封面 →(→) 上一首 → 播放/暂停 → 下一首 → 队列',
        (WidgetTester tester) async {
      await ready(tester);
      await pumpMini(tester);
      await focusCover(tester);

      const List<String> forward = <String>[
        'mini.prev',
        'mini.play',
        'mini.next',
        'mini.queue',
      ];
      for (int i = 0; i < forward.length; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        expect(focusedLabel(), forward[i],
            reason: '第 ${i + 1} 次 → 应该到 ${forward[i]}'
                '（顺序必须是 封面 → 上一首 → 播放/暂停 → 下一首 → 队列）');
      }

      // 反向原路返回
      const List<String> backward = <String>[
        'mini.next',
        'mini.play',
        'mini.prev',
        'mini.cover',
      ];
      for (int i = 0; i < backward.length; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        expect(focusedLabel(), backward[i],
            reason: '第 ${i + 1} 次 ← 应该到 ${backward[i]}');
      }

      await tearDownTree(tester);
    });

    testWidgets('歌曲名与歌手只展示、不抢占焦点', (WidgetTester tester) async {
      await ready(tester);
      await pumpMini(tester);
      await focusCover(tester);

      // 整条播放条里，`mini.*` 节点**只有五个**，而且都不在文字那一侧
      final Iterable<Focus> allFocus = tester.widgetList<Focus>(
        find.byType(Focus),
      );
      final List<String> miniLabels = allFocus
          .map((Focus f) => f.focusNode?.debugLabel ?? '')
          .where((String l) => l.startsWith('mini.'))
          .toList();
      expect(miniLabels.toSet(), <String>{
        'mini.cover',
        'mini.prev',
        'mini.play',
        'mini.next',
        'mini.queue',
      }, reason: '只能有这五个焦点节点');

      // 曲目文字**不能**有任何 mini.* 的 Focus 祖先
      final Iterable<Focus> textAncestors = tester.widgetList<Focus>(
        find.ancestor(
          of: find.text('曲目 g1'),
          matching: find.byType(Focus),
        ),
      );
      expect(
        textAncestors.where(
          (Focus f) => (f.focusNode?.debugLabel ?? '').startsWith('mini.'),
        ),
        isEmpty,
        reason: '焦点若停在歌曲文字上，按 OK 什么也不会发生，用户会以为遥控器坏了',
      );

      await tearDownTree(tester);
    });
  });

  group('封面与队列按钮的动作', () {
    testWidgets('封面按 OK = 打开完整播放页，且焦点不丢',
        (WidgetTester tester) async {
      await ready(tester);
      await pumpMini(tester);
      await focusCover(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(openPlayerCalls, 1);
      expect(focusedLabel(), 'mini.cover', reason: '焦点必须留在封面上');

      await tearDownTree(tester);
    });

    testWidgets('队列按钮按 OK = 打开当前播放队列（不是整张音乐库）',
        (WidgetTester tester) async {
      await ready(tester);
      await pumpMini(tester);
      await focusCover(tester);

      for (int i = 0; i < 4; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      }
      expect(focusedLabel(), 'mini.queue');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(openQueueCalls, 1);
      expect(focusedLabel(), 'mini.queue');

      await tearDownTree(tester);
    });

    testWidgets('上一首 / 下一首 / 播放暂停 都能激活，且焦点不跳走',
        (WidgetTester tester) async {
      await ready(tester);
      await pumpMini(tester);
      await focusCover(tester);
      expect(playback.currentIndex, 1);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(), 'mini.prev');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();
      expect(playback.currentIndex, 0, reason: 'OK 应切到上一首');
      expect(focusedLabel(), 'mini.prev');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter); // 播放/暂停
      await tester.pump();
      expect(engine.pauseCalls, 1);
      expect(focusedLabel(), 'mini.play');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(), 'mini.next');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();
      expect(playback.currentIndex, 1, reason: 'OK 应切到下一首');
      expect(focusedLabel(), 'mini.next');

      await tearDownTree(tester);
    });
  });

  group('没有当前曲目时不渲染', () {
    testWidgets('未播放任何歌曲 → 迷你播放器不占位', (WidgetTester tester) async {
      await pumpMini(tester);
      expect(playback.current, isNull);
      expect(find.byType(MiniPlayer), findsOneWidget);
      expect(find.byType(TvGlass), findsNothing,
          reason: '没有曲目时整条应缩成 SizedBox.shrink()，不该有残留的玻璃底板');
      await tearDownTree(tester);
    });
  });
}
