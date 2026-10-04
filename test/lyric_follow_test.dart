import 'package:feiniu_tv_music/domain/album.dart';
import 'package:feiniu_tv_music/domain/artist.dart';
import 'package:feiniu_tv_music/domain/lyric.dart';
import 'package:feiniu_tv_music/domain/track.dart';
import 'package:feiniu_tv_music/repositories/lyric_repository.dart';
import 'package:feiniu_tv_music/repositories/playback_repository.dart';
import 'package:feiniu_tv_music/ui/widgets/lyric_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import 'support/fake_lyric_source.dart';
import 'support/fake_music_repository.dart';
import 'support/fake_playback_engine.dart';

/// 歌词**跟随播放进度**的回归（需求：进度与歌词必须是同一条时间轴）。
///
/// ## 「定时器存在」≠「同步正确」
///
/// 旧实现有一个 400ms 定时器读 `playback.position`，链路看起来是通的，
/// 但有两个会让它**在电视上完全不动**的缺口：
///
/// 1. **NAS 返回纯文本歌词源**（无 `[mm:ss]` 标签）时，
///    `LyricDoc.fromJson` 把整段文本塞成**一行**且 `time` 可能为 null
///    ⇒ `activeLineIndex()` 永远返回 -1 ⇒ 高亮与滚动都不动。
///    修复：纯文本按换行拆成多行、界面标注「不支持逐句同步」；
///    LRC 源继续逐句同步，并把源级 `offset`（秒）叠加进时间轴。
/// 2. **进度来源是 400ms 轮询**：seek（遥控器 / 手机 / 拖动）之后最多要等
///    400ms 才重算。修复：改订阅引擎的 `positionStream`（seek 立即发值），
///    并在文档替换后的首帧立即按当前进度定位一次。
///
/// 本文件用「虚拟音频进度 + 时间点已知的 LRC」把这条链路钉死。
void main() {
  late FakeMusicRepository music;
  late FakePlaybackEngine engine;
  late PlaybackRepository playback;

  /// 8 行、时间点已知（0/10/20/30/40/50/60/70 秒）的 LRC。
  const String lrc = '[00:00.00]第一句\n'
      '[00:10.00]第二句\n'
      '[00:20.00]第三句\n'
      '[00:30.00]第四句\n'
      '[00:40.00]第五句\n'
      '[00:50.00]第六句\n'
      '[01:00.00]第七句\n'
      '[01:10.00]第八句';

  Track track([String guid = 'g1']) => Track(
        guid: guid,
        title: '测试歌',
        durationMs: 90000,
        album: const AlbumRef(guid: 'al1', name: '专辑'),
        artists: <ArtistRef>[const ArtistRef(guid: 'ar1', name: '歌手')],
        audioSpec: const AudioSpec(format: 'flac'),
      );

  setUp(() {
    music = FakeMusicRepository();
    engine = FakePlaybackEngine();
    playback = PlaybackRepository(music: music, handler: engine);
  });

  tearDown(() async {
    playback.dispose();
    await engine.close();
  });

  /// 某一行当前是不是「正在唱」的活动行（活动行加粗）。
  bool isActive(WidgetTester tester, String text) {
    final Finder f = find.text(text);
    if (f.evaluate().isEmpty) return false;
    for (final Element e in f.evaluate()) {
      final Widget w = e.widget;
      if (w is Text && w.style?.fontWeight == FontWeight.w700) return true;
    }
    return false;
  }

  Future<LyricRepository> pumpLyrics(
    WidgetTester tester, {
    required LyricRepository lyrics,
  }) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: <SingleChildWidget>[
          ChangeNotifierProvider<PlaybackRepository>.value(value: playback),
          ChangeNotifierProvider<LyricRepository>.value(value: lyrics),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SizedBox(height: 400, child: LyricView())),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return lyrics;
  }

  group('解析（进度 → 行）', () {
    test('A 八行 LRC 全部带时间轴，乱序输入按时间排序', () {
      final LyricDoc doc = LyricDoc.parse(
        '[00:30.00]第四句\n[00:00.00]第一句\n[00:50.00]第六句\n'
        '[00:10.00]第二句\n[00:40.00]第五句\n[00:20.00]第三句\n'
        '[01:00.00]第七句\n[01:10.00]第八句',
      );
      expect(doc.lines.length, 8);
      expect(doc.isSyncable, isTrue);
      for (int i = 0; i < 8; i++) {
        expect(doc.lines[i].text, '第${'一二三四五六七八'[i]}句',
            reason: '第 $i 行应按时间排序');
        expect(doc.lines[i].time, Duration(seconds: i * 10));
      }
    });

    test('B 多标签 / 厘秒 / 毫秒 / 无小数 / 同时间多行 / 元数据', () {
      final LyricDoc doc = LyricDoc.parse(
        '[00:10.00][00:20.00]重复句\n' // 多标签 → 两行
            '[00:12.34]厘秒\n' // .34 → 340ms
            '[00:13.345]毫秒\n' // .345 → 345ms
            '[0:14]无小数\n' // 14s
            '[00:15.00]同刻其一\n[00:15.00]同刻其二\n' // 同时间多行
            '[ar:某人]\n[ti:某歌]\n', // 元数据 → 丢弃
      );
      expect(doc.lines.length, 7, reason: '元数据行不产出歌词行');
      // ⚠️ 期望值必须按**排序后**的顺序写：parseLrc 输出按时间排序
      //    （10 → 12.34 → 13.345 → 14 → 15 → 15 → 20），
      //    上一版把「输入顺序」当成了「结果顺序」，20s 的重复句被
      //    想当然地放在了 lines[1]。
      expect(doc.lines[0].time, const Duration(seconds: 10));
      expect(doc.lines[0].text, '重复句');
      expect(doc.lines[1].time, const Duration(seconds: 12, milliseconds: 340));
      expect(doc.lines[1].text, '厘秒');
      expect(doc.lines[2].time, const Duration(seconds: 13, milliseconds: 345));
      expect(doc.lines[2].text, '毫秒');
      expect(doc.lines[3].time, const Duration(seconds: 14));
      expect(doc.lines[3].text, '无小数');
      expect(doc.lines[4].time, const Duration(seconds: 15));
      expect(doc.lines[4].text, '同刻其一', reason: '同刻两行保持输入顺序');
      expect(doc.lines[5].time, const Duration(seconds: 15));
      expect(doc.lines[5].text, '同刻其二');
      expect(doc.lines[6].time, const Duration(seconds: 20));
      expect(doc.lines[6].text, '重复句');
    });

    test('C `[offset:+500]` 整体偏移 500ms', () {
      final LyricDoc doc =
          LyricDoc.parse('[offset:+500]\n[00:10.00]句一\n[00:20.00]句二');
      expect(doc.lines[0].time, const Duration(seconds: 10, milliseconds: 500));
      expect(doc.lines[1].time, const Duration(seconds: 20, milliseconds: 500));
    });

    test('D 纯文本（无时间轴）→ 按换行拆多行、全部无时间、顺序不变', () {
      final LyricDoc doc = LyricDoc.parse('第一段\n第二段\n\n第三段');
      expect(doc.lines.length, 3, reason: '空行丢弃，其余各成一行');
      expect(doc.isSyncable, isFalse, reason: '没有时间轴 ⇒ 不能逐句同步');
      for (int i = 0; i < 3; i++) {
        expect(doc.lines[i].time, isNull);
      }
      expect(doc.lines[0].text, '第一段');
      expect(doc.lines[2].text, '第三段');
    });

    test('E NAS 源级 offset（秒）叠加进 LRC 时间轴', () {
      final LyricDoc doc = LyricDoc.fromJson(<String, dynamic>{
        'list': <Object?>[
          <String, dynamic>{
            'text': '[00:10.00]句一\n[00:20.00]句二',
            'offset': 3, // 秒
          },
        ],
        'preferred': 0,
      });
      expect(doc.isSyncable, isTrue);
      expect(doc.lines[0].time, const Duration(seconds: 13));
      expect(doc.lines[1].time, const Duration(seconds: 23));
    });

    test('F NAS 纯文本源 → 多行且不可同步（旧行为是挤成一行）', () {
      final LyricDoc doc = LyricDoc.fromJson(<String, dynamic>{
        'list': <Object?>[
          <String, dynamic>{'text': '第一段\n第二段\n第三段'},
        ],
        'preferred': 0,
      });
      expect(doc.lines.length, 3, reason: '旧实现整段塞一行，多段歌词被吞');
      expect(doc.isSyncable, isFalse);
    });
  });

  group('跟随（虚拟音频进度 → 高亮与滚动）', () {
    testWidgets('G 从 0 播放：第 0 句高亮', (WidgetTester tester) async {
      final LyricRepository lyrics =
          LyricRepository(FakeLyricSource(doc: LyricDoc.parse(lrc)));
      await pumpLyrics(tester, lyrics: lyrics);
      await tester.runAsync(() async {
        await lyrics.load(track());
        playback.setQueue(<Track>[track()], startIndex: 0);
        await playback.pendingLoads;
      });
      await tester.pump();
      await tester.pump();

      expect(isActive(tester, '第一句'), isTrue, reason: '0 秒应对应第一句');
      expect(isActive(tester, '第二句'), isFalse);
    });

    testWidgets('H seek 到 00:45 → 立即定位第五句（40s 那句）',
        (WidgetTester tester) async {
      final LyricRepository lyrics =
          LyricRepository(FakeLyricSource(doc: LyricDoc.parse(lrc)));
      await pumpLyrics(tester, lyrics: lyrics);
      await tester.runAsync(() async {
        await lyrics.load(track());
        playback.setQueue(<Track>[track()], startIndex: 0);
        await playback.pendingLoads;
      });
      await tester.pump();
      await tester.pump();

      engine.setPosition(const Duration(seconds: 45));
      await tester.pump();
      await tester.pump();

      // ⚠️ 断言分层（实测教训）：测试绑定下 ListView 的 cacheExtent
      //    不生效（显式传了也被忽略），视口外（>370px）的行不会构建，
      //    `find.text` 断言视口外的行会得到 Count=0 —— 那是测试环境
      //    的产物，不是产品缺陷。所以机制层断言走 State 的诊断面；
      //    可见行的样式断言由 G/K/M/N 覆盖。
      final dynamic st = tester.state(find.byType(LyricView));
      expect(st.debugActiveIndex, 4,
          reason: '45 秒落在 40–50s 的句子里，必须立即定位该句，不必等播放自然走到');
      expect(st.debugLastScrollTarget, closeTo(4 * 64, 0.5),
          reason: '必须同时发出「把第 4 行滚到视口中部」的滚动指令');
    });

    testWidgets('I 拖回 00:12 → 回滚到第二句', (WidgetTester tester) async {
      final LyricRepository lyrics =
          LyricRepository(FakeLyricSource(doc: LyricDoc.parse(lrc)));
      await pumpLyrics(tester, lyrics: lyrics);
      await tester.runAsync(() async {
        await lyrics.load(track());
        playback.setQueue(<Track>[track()], startIndex: 0);
        await playback.pendingLoads;
      });
      await tester.pump();
      await tester.pump();

      engine.setPosition(const Duration(seconds: 45));
      await tester.pump();
      await tester.pump();
      final dynamic before = tester.state(find.byType(LyricView));
      expect(before.debugActiveIndex, 4, reason: '45 秒先定位到第五句（40s 那句）');

      engine.setPosition(const Duration(seconds: 12));
      await tester.pump();
      await tester.pump();
      final dynamic st = tester.state(find.byType(LyricView));
      expect(st.debugActiveIndex, 1, reason: 'seek 回 12 秒必须回滚到第二句（10s 那句）');
      expect(st.debugLastScrollTarget, closeTo(1 * 64, 0.5),
          reason: '回滚也必须伴随正确的滚动指令');
    });

    testWidgets('J 活动行前进时列表真的滚动（不是只变色）',
        (WidgetTester tester) async {
      final LyricRepository lyrics =
          LyricRepository(FakeLyricSource(doc: LyricDoc.parse(lrc)));
      await pumpLyrics(tester, lyrics: lyrics);
      await tester.runAsync(() async {
        await lyrics.load(track());
        playback.setQueue(<Track>[track()], startIndex: 0);
        await playback.pendingLoads;
      });
      await tester.pump();
      await tester.pump();

      // 跳到最后一行：必须发出「滚到第 7 行」的指令，且活动行确实前进了
      //（7×64=448 clamp 后仍 ≥ 400，证明不是停在开头）。
      // ⚠️ 断言分层说明见 H：测试绑定下 cacheExtent 不生效，
      //    视口外的行不构建，`find.text` 断言会拿到 Count=0，
      //    所以滚动断的是「指令目标」而不是渲染后的矩形/像素。
      engine.setPosition(const Duration(seconds: 75));
      await tester.pump();
      await tester.pump();
      final dynamic st = tester.state(find.byType(LyricView));
      expect(st.debugActiveIndex, 7, reason: '75 秒应对应第八句（70s 那句）');
      expect(st.debugLastScrollTarget, greaterThan(200),
          reason: '活动行前进后必须发出真实的滚动指令（目标 ≈ 448），而不是停在开头');
    });

    testWidgets('K 暂停 / 恢复：高亮停在正确的句子，不漂移',
        (WidgetTester tester) async {
      final LyricRepository lyrics =
          LyricRepository(FakeLyricSource(doc: LyricDoc.parse(lrc)));
      await pumpLyrics(tester, lyrics: lyrics);
      await tester.runAsync(() async {
        await lyrics.load(track());
        playback.setQueue(<Track>[track()], startIndex: 0);
        await playback.pendingLoads;
      });
      await tester.pump();
      await tester.pump();

      engine.setPosition(const Duration(seconds: 33));
      await tester.pump();
      await tester.pump();
      expect(isActive(tester, '第四句'), isTrue);

      // 暂停（进度不变）→ 再怎么刷新也不应漂移
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(isActive(tester, '第四句'), isTrue, reason: '暂停时进度不变，高亮必须停在原句');
    });

    testWidgets('L 切歌：旧歌词/旧高亮被清掉，新歌按当前进度定位',
        (WidgetTester tester) async {
      final LyricRepository lyrics = LyricRepository(
        FakeLyricSource(docsByGuid: <String, LyricDoc>{
          'g1': LyricDoc.parse(lrc),
          'g2': LyricDoc.parse('[00:00.00]新歌一\n[00:05.00]新歌二\n[00:09.00]新歌三'),
        }),
      );
      await pumpLyrics(tester, lyrics: lyrics);
      await tester.runAsync(() async {
        await lyrics.load(track('g1'));
        playback.setQueue(<Track>[track('g1'), track('g2')], startIndex: 0);
        await playback.pendingLoads;
      });
      await tester.pump();
      await tester.pump();

      engine.setPosition(const Duration(seconds: 45));
      await tester.pump();
      await tester.pump();
      expect(isActive(tester, '第五句'), isTrue);

      // 切歌（播放页在曲目变化时会调用 lyrics.load —— 这里模拟同一路径）
      await tester.runAsync(() async {
        await lyrics.load(track('g2'), force: true);
      });
      await tester.pump();
      await tester.pump();

      expect(find.text('第五句'), findsNothing, reason: '旧歌词必须被清掉，不得残留');
      expect(find.text('新歌三'), findsOneWidget, reason: '新歌词的行必须已经显示');
      final dynamic st = tester.state(find.byType(LyricView));
      expect(st.debugActiveIndex, 2,
          reason: '新歌词到达后必须按**当前音频进度**（45s > 新歌全部时间点）'
              '定位到最后一行，而不是从第 0 秒重新来');
    });

    testWidgets('M 纯文本歌词：完整显示 + 明确标注不支持逐句同步',
        (WidgetTester tester) async {
      final LyricRepository lyrics = LyricRepository(
        FakeLyricSource(doc: LyricDoc.parse('第一段歌词\n第二段歌词\n第三段歌词')),
      );
      await pumpLyrics(tester, lyrics: lyrics);
      await tester.runAsync(() async {
        await lyrics.load(track());
      });
      await tester.pump();
      await tester.pump();

      expect(find.text('纯文本歌词 · 不支持逐句同步'), findsOneWidget,
          reason: '没有时间轴必须明说，不能让用户以为歌词坏了');
      expect(find.text('第一段歌词'), findsOneWidget);
      expect(find.text('第二段歌词'), findsOneWidget);
      expect(find.text('第三段歌词'), findsOneWidget);
      expect(isActive(tester, '第一段歌词'), isFalse,
          reason: '纯文本没有时间轴，不能伪造当前高亮');
    });

    testWidgets('N 滚动控制器晚 attach：切布局后仍按当前进度定位',
        (WidgetTester tester) async {
      final LyricRepository lyrics =
          LyricRepository(FakeLyricSource(doc: LyricDoc.parse(lrc)));
      await tester.runAsync(() async {
        await lyrics.load(track());
        playback.setQueue(<Track>[track()], startIndex: 0);
        await playback.pendingLoads;
      });
      engine.setPosition(const Duration(seconds: 45));

      // 先渲染一个很小的视口（模拟「切布局 / 视口尺寸为 0」），再恢复正常
      await tester.pumpWidget(
        MultiProvider(
          providers: <SingleChildWidget>[
            ChangeNotifierProvider<PlaybackRepository>.value(value: playback),
            ChangeNotifierProvider<LyricRepository>.value(value: lyrics),
          ],
          child: const MaterialApp(
            home: Scaffold(body: SizedBox(height: 1, child: LyricView())),
          ),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(
        MultiProvider(
          providers: <SingleChildWidget>[
            ChangeNotifierProvider<PlaybackRepository>.value(value: playback),
            ChangeNotifierProvider<LyricRepository>.value(value: lyrics),
          ],
          child: const MaterialApp(
            home: Scaffold(body: SizedBox(height: 400, child: LyricView())),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 320)); // 等定位动画完成

      expect(isActive(tester, '第五句'), isTrue,
          reason: '视口从 0 恢复后必须按当前进度重新定位，不能停在开头');
      // 光「标记了高亮」不够 —— 行必须真的被滚进 400 高的视口里。
      final Rect activeRect = tester.getRect(find.text('第五句'));
      expect(activeRect.top, greaterThanOrEqualTo(-0.5),
          reason: '活动行顶部不得在视口上方被裁: $activeRect');
      expect(activeRect.bottom, lessThanOrEqualTo(400.5),
          reason: '活动行底部不得在视口下方被裁: $activeRect');
    });
  });
}
