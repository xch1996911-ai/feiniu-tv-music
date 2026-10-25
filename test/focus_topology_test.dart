import 'package:feiniu_tv_music/app/theme.dart';
import 'package:feiniu_tv_music/domain/album.dart';
import 'package:feiniu_tv_music/domain/artist.dart';
import 'package:feiniu_tv_music/domain/track.dart';
import 'package:feiniu_tv_music/repositories/library_repository.dart';
import 'package:feiniu_tv_music/repositories/local_library_repository.dart';
import 'package:feiniu_tv_music/repositories/music_repository.dart';
import 'package:feiniu_tv_music/repositories/playback_repository.dart';
import 'package:feiniu_tv_music/ui/focus/stage_focus.dart';
import 'package:feiniu_tv_music/ui/pages/track_list_page.dart';
import 'package:feiniu_tv_music/ui/widgets/track_row.dart';
import 'package:feiniu_tv_music/ui/widgets/tv_focus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_music_repository.dart';
import 'support/fake_playback_engine.dart';
import 'support/fake_secure_store.dart';

/// 焦点语义：**主内容层 / Mini 主控层 / 次级层**三层分离的回归测试。
///
/// 对应实机 P0（海信 E7N Pro 85"）三宗罪：
/// 1. 进入「最近添加」默认焦点落在收藏类次级按钮上；
/// 2. 底部条按 ↑ 会弹出「收藏 / 模式」；
/// 3. 歌曲行右侧心形形成一条「纵列」，↓ 一路滑到底回不到歌名。
///
/// 这些全是焦点树结构问题 —— 只有 widget 测试抓得到，肉眼验收抓不到。
Track _track(String guid, {int createdAt = 1}) => Track(
      guid: guid,
      title: '曲目 $guid',
      durationMs: 180000,
      // 入库时间（真实字段是 DateTime，来自 Unix 秒）。
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt * 1000),
      album: AlbumRef(guid: 'a_$guid', name: '专辑 $guid'),
      artists: <ArtistRef>[ArtistRef(guid: 'r_$guid', name: '歌手 $guid')],
      audioSpec: const AudioSpec(format: 'flac', sampleRate: 44100, bitDepth: 16),
    );

void main() {
  // 纯逻辑用例里也要建 FocusNode —— `FocusManager.instance` 依赖
  // WidgetsBinding，必须先初始化绑定，否则第一条 group 直接抛。
  TestWidgetsFlutterBinding.ensureInitialized();
  // ── 一、分层判定与记忆（纯逻辑）──────────────────────────────

  group('StageFocus：焦点分层与恢复', () {
    test('按 debugLabel 前缀分层', () {
      expect(
        StageFocus.layerOf(FocusNode(debugLabel: 'mini.cover')),
        TvFocusLayer.mini,
      );
      expect(
        StageFocus.layerOf(FocusNode(debugLabel: 'extra.fav')),
        TvFocusLayer.mini,
      );
      expect(
        StageFocus.layerOf(FocusNode(debugLabel: 'nav.0')),
        TvFocusLayer.nav,
      );
      expect(
        StageFocus.layerOf(FocusNode(debugLabel: 'shell.search')),
        TvFocusLayer.nav,
      );
      expect(
        StageFocus.layerOf(FocusNode(debugLabel: 'player.play')),
        TvFocusLayer.overlay,
      );
      expect(
        StageFocus.layerOf(FocusNode(debugLabel: 'list.row.0')),
        TvFocusLayer.content,
      );
      expect(
        StageFocus.layerOf(FocusNode(debugLabel: 'track.fav')),
        TvFocusLayer.content,
      );
    });

    test('只在内容层更新「最近正文焦点」', () {
      final StageFocus stage = StageFocus();
      final FocusNode content = FocusNode(debugLabel: 'list.row.3');
      final FocusNode nav = FocusNode(debugLabel: 'nav.2');
      final FocusNode mini = FocusNode(debugLabel: 'mini.play');

      stage.note(content);
      expect(stage.debugLastContent, same(content));

      // 焦点进导航栏 / 底部条 → 不覆盖正文记忆，
      // 否则 Mini ↑ 会「回到导航栏」或「回到自己」。
      stage.note(nav);
      expect(stage.debugLastContent, same(content), reason: '导航层不得覆盖');
      stage.note(mini);
      expect(stage.debugLastContent, same(content), reason: 'Mini 层不得覆盖');

      stage.dispose();
      content.dispose();
      nav.dispose();
      mini.dispose();
    });

    test('已卸载 / 不存在的节点不会被聚焦（返回 false 而不是抛异常）', () {
      final StageFocus stage = StageFocus();
      expect(StageFocus.focus(null), isFalse);

      // 从未挂到树上的节点：context 为 null → 视为不可用。
      final FocusNode orphan = FocusNode(debugLabel: 'list.row.9');
      expect(StageFocus.alive(orphan), isFalse);
      expect(StageFocus.focus(orphan), isFalse);

      orphan.dispose();
      stage.dispose();
    });

    test('切页清空记忆，避免指向上一页已销毁的节点', () {
      final StageFocus stage = StageFocus();
      final FocusNode n = FocusNode(debugLabel: 'home.漫游');
      stage.registerDefault(n);
      stage.note(n);
      expect(stage.debugStageDefault, same(n));
      expect(stage.debugLastContent, same(n));

      stage.clearStage();
      expect(stage.debugStageDefault, isNull);
      expect(stage.debugLastContent, isNull);

      n.dispose();
      stage.dispose();
    });

    test('TrackRowFocus 按下标建节点：同一行始终是同一个 FocusNode', () {
      final TrackRowFocus rows = TrackRowFocus('list.row');

      // 列表因为同步推进而在头部插入新歌时，节点跟着**下标**走，
      // 而不是跟着歌曲 guid 走 —— 否则焦点会随歌跑掉。
      expect(rows.at(0), same(rows.at(0)));
      expect(rows.at(1), isNot(same(rows.at(0))));
      expect(rows.at(0).debugLabel, 'list.row.0');
      expect(rows.at(2).debugLabel, 'list.row.2');

      // 行的上下邻居必须显式给出，且到边界返回 null（由调用方决定接到哪）。
      expect(rows.above(0), isNull);
      expect(rows.above(2), same(rows.at(1)));
      expect(rows.below(2, 3), isNull, reason: '最后一行 ↓ 归调用方接 Mini');
      expect(rows.below(0, 3), same(rows.at(1)));

      rows.dispose();
      expect(rows.debugLength, 0);
    });
  });

  // ── 二、最近添加页的焦点拓扑（实机 Case A / B / C）─────────────

  group('「最近添加」页焦点拓扑', () {
    late FakeMusicRepository music;
    late FakePlaybackEngine engine;
    late PlaybackRepository playback;
    late LibraryRepository library;
    late LocalLibraryRepository local;
    late StageFocus stage;
    late FocusNode miniCover;
    late FocusNode miniPlay;

    setUp(() {
      music = FakeMusicRepository();
      engine = FakePlaybackEngine();
      playback = PlaybackRepository(music: music, handler: engine);
      library = LibraryRepository(music);
      local = LocalLibraryRepository(store: FakeSecureStore());
      stage = StageFocus();
      miniCover = FocusNode(debugLabel: 'mini.cover');
      miniPlay = FocusNode(debugLabel: 'mini.play');
    });

    tearDown(() async {
      library.dispose();
      playback.dispose();
      local.dispose();
      stage.dispose();
      miniCover.dispose();
      miniPlay.dispose();
      await engine.close();
    });

    String? focusedLabel() => FocusManager.instance.primaryFocus?.debugLabel;

    Future<void> pumpPage(WidgetTester tester, {int count = 3}) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      music.catalogue = <Track>[
        for (int i = 0; i < count; i++) _track('t$i', createdAt: 1000 + i),
      ];
      await tester.runAsync(() => library.loadFirst());

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<LibraryRepository>.value(value: library),
            ChangeNotifierProvider<PlaybackRepository>.value(value: playback),
            ChangeNotifierProvider<LocalLibraryRepository>.value(value: local),
            ChangeNotifierProvider<MusicRepository>.value(value: music),
          ],
          child: MaterialApp(
            theme: buildTvTheme(),
            home: Scaffold(
              body: StageFocusScope(
                stage: stage,
                miniCover: miniCover,
                miniPlay: miniPlay,
                child: Column(
                  children: <Widget>[
                    Expanded(
                      child: TrackListPage(
                        source: TrackListSource.recentlyAdded,
                        title: '最近添加',
                        emptyText: '暂无最近添加',
                        emptyIcon: Icons.fiber_new,
                        onOpenPlayer: () {},
                      ),
                    ),
                    // 真实的 Mini Player 不在本用例范围内，
                    // 但「列表到底 ↓ 落到播放条」需要这个节点真的在树上。
                    SizedBox(
                      height: 60,
                      child: TvFocus(
                        focusNode: miniCover,
                        debugLabel: 'mini.cover',
                        onPressed: () {},
                        builder: (BuildContext c, TvFocusStatus s) =>
                            const SizedBox(width: 60, height: 60),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    Future<void> tearDownTree(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }

    testWidgets('Case A：进入页面默认焦点 = 第一首歌的整行（不是心形）',
        (WidgetTester tester) async {
      await pumpPage(tester);

      // 页面应该已经把「默认首焦点」登记给 Shell 了
      expect(stage.debugStageDefault?.debugLabel, 'list.row.0',
          reason: 'Shell 切页时会直接聚焦它；登记的若不是第一行，'
              '实机就仍然落在导航栏/收藏上');

      expect(stage.focusStageDefault(), isTrue);
      await tester.pump();
      expect(focusedLabel(), 'list.row.0');

      // 反证：绝不是收藏心形
      expect(focusedLabel(), isNot(contains('fav')));

      await tearDownTree(tester);
    });

    testWidgets('Case B：↓ 逐行向下，按歌曲顺序移动',
        (WidgetTester tester) async {
      await pumpPage(tester);
      stage.focusStageDefault();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'list.row.1');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'list.row.2');

      await tearDownTree(tester);
    });

    testWidgets('↑ 逐行向上；第一行 ↑ 到页头真实主入口', (WidgetTester tester) async {
      await pumpPage(tester);
      stage.focusStageDefault();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'list.row.1');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), 'list.row.0');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), 'list.append',
          reason: '第一行的 ↑ 应该去「加入播放队列」这个真实存在的页头入口，'
              '而不是被甩到左侧导航');

      await tearDownTree(tester);
    });

    testWidgets('心形只有 → 才进得去，进去后 ↓ 回「下一行的整行」而不是下一个心形',
        (WidgetTester tester) async {
      await pumpPage(tester);
      stage.focusStageDefault();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'list.row.1');

      // 主动 → 才进入行内次级控件
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(), 'track.fav',
          reason: '→ 才允许进入行内收藏按钮');

      // 关键：↓ 必须回**下一行的整行**。
      // 若回 'track.fav' 就说明焦点留在了心形纵列里（实机 Bug）。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'list.row.2');

      // ← 回本行整行
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), 'list.row.1');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(), 'track.fav');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(focusedLabel(), 'list.row.1');

      await tearDownTree(tester);
    });

    testWidgets('Case C：列表最后一行 ↓ 落到 Mini Player 封面',
        (WidgetTester tester) async {
      await pumpPage(tester);
      stage.focusStageDefault();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'list.row.2');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'mini.cover');

      await tearDownTree(tester);
    });
  });
}
