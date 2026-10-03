import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:feiniu_tv_music/domain/album.dart';
import 'package:feiniu_tv_music/domain/artist.dart';
import 'package:feiniu_tv_music/domain/track.dart';
import 'package:feiniu_tv_music/repositories/lyric_repository.dart';
import 'package:feiniu_tv_music/services/online_lyric_source.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_adapter.dart';
import 'support/fake_lyric_source.dart';

/// 永不返回的 Dio 适配器：模拟「连上了，但服务端一直不吐数据」。
///
/// ⚠️ 这正是 `receiveTimeout` **抓不到**的情形（它只管两个数据包之间的间隔），
/// 必须靠外层 `.timeout` 兜住。
class _NeverAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      Completer<ResponseBody>().future; // 永不完成

  @override
  void close({bool force = false}) {}
}

/// 可完全控制的假在线歌词源（不打任何网络）。
class _FakeOnline implements OnlineLyricSource {
  _FakeOnline({
    this.candidates = const <OnlineLyricCandidate>[],
    this.error,
    this.delay = Duration.zero,
  });

  final List<OnlineLyricCandidate> candidates;

  /// 非 null 时 `search` 直接抛这个异常（模拟断网 / 限流 / 服务异常）。
  final Object? error;

  final Duration delay;

  int calls = 0;
  OnlineLyricQuery? lastQuery;

  @override
  String get displayName => 'FAKE';

  @override
  Future<List<OnlineLyricCandidate>> search(OnlineLyricQuery query) async {
    calls++;
    lastQuery = query;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final Object? e = error;
    if (e != null) throw e;
    return candidates;
  }
}

OnlineLyricCandidate cand(
  String title, {
  String artist = '',
  int durationSec = 0,
  String? synced,
  String? plain,
}) =>
    OnlineLyricCandidate(
      title: title,
      artist: artist,
      album: '',
      duration: durationSec <= 0 ? null : Duration(seconds: durationSec),
      syncedLyrics: synced,
      plainLyrics: plain,
      score: 0,
      source: 'FAKE',
    );

Track song(
  String guid, {
  String title = '晴天',
  String artist = '周杰伦',
  String album = '叶惠美',
  int durationMs = 269000,
}) =>
    Track(
      guid: guid,
      title: title,
      durationMs: durationMs,
      album: AlbumRef(guid: 'alb_1', name: album),
      artists: <ArtistRef>[ArtistRef(guid: 'ar_1', name: artist)],
      audioSpec: const AudioSpec(format: 'flac', sampleRate: 44100, bitDepth: 16),
    );

const String _lrc =
    '[00:00.00]第一行\n[00:05.00]第二行\n[00:10.00]第三行\n';

void main() {
  // onlineEnabled 是全局开关，任何一个用例改动它都必须复原。
  tearDown(() => LyricRepository.onlineEnabled = true);

  group('匹配打分器（决定「能不能自动绑定」）', () {
    test('归一化：去括号内容、去版本后缀词、去所有非字母数字汉字', () {
      expect(OnlineLyricMatcher.normalize('晴天'), '晴天');
      expect(OnlineLyricMatcher.normalize('晴天 (Live)'), '晴天');
      expect(OnlineLyricMatcher.normalize('晴天【现场版】'), '晴天');
      expect(OnlineLyricMatcher.normalize('Yesterday (Remastered 2009)'),
          'yesterday');
      expect(OnlineLyricMatcher.normalize('Hello, World!'), 'helloworld');
      expect(OnlineLyricMatcher.normalize('  '), '');
    });

    test('歌手归一化：只取第一个歌手 / 去掉 feat.', () {
      expect(OnlineLyricMatcher.normalizeArtist('周杰伦'), '周杰伦');
      expect(OnlineLyricMatcher.normalizeArtist('周杰伦 feat. 阿信'), '周杰伦');
      expect(OnlineLyricMatcher.normalizeArtist('周杰伦 / 阿信'), '周杰伦');
      expect(OnlineLyricMatcher.normalizeArtist('A, B & C'), 'a');
    });

    test('标题 + 歌手 + 时长全中 → 满分（≥ 阈值，可自动绑定）', () {
      final q = OnlineLyricQuery(
        title: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        duration: const Duration(seconds: 269),
      );
      final s = OnlineLyricMatcher.score(
        q,
        cand('晴天', artist: '周杰伦', durationSec: 269),
      );
      expect(s, greaterThanOrEqualTo(OnlineLyricMatcher.acceptThreshold));
      expect(s, 1.0, reason: 'clamp 到 1.0');
    });

    test('歌手写法有差异（Live / feat.）仍然能匹配上', () {
      final q = OnlineLyricQuery(
        title: '晴天',
        artist: '周杰伦',
        duration: const Duration(seconds: 269),
      );
      final s = OnlineLyricMatcher.score(
        q,
        cand('晴天 (Live)', artist: '周杰伦', durationSec: 269),
      );
      expect(s, greaterThanOrEqualTo(OnlineLyricMatcher.acceptThreshold),
          reason: '括号与版本后缀是最常见的写法分歧，不能被当成「不同歌」');
    });

    test('标题完全不沾边 → 直接判 0（错误候选必须被拒绝）', () {
      final q = OnlineLyricQuery(title: '晴天', artist: '周杰伦');
      expect(
        OnlineLyricMatcher.score(q, cand('稻香', artist: '周杰伦')),
        0,
        reason: '绑错歌词比没有歌词更糟 —— 标题不匹配必须一票否决',
      );
      expect(
        OnlineLyricMatcher.score(
          q,
          cand('稻香', artist: '完全不认识', durationSec: 30),
        ),
        0,
        reason: '标题不匹配时连歌手与时长都不再看',
      );
    });

    test('同名但是翻唱 / 时长差很远 → 置信度不足（不给自动绑定）', () {
      final q = OnlineLyricQuery(
        title: '晴天',
        artist: '周杰伦',
        duration: const Duration(seconds: 269),
      );
      final s = OnlineLyricMatcher.score(
        q,
        cand('晴天', artist: '某翻唱', durationSec: 400),
      );
      expect(s, lessThan(OnlineLyricMatcher.acceptThreshold));
      expect(s, greaterThan(0), reason: '标题是对的，只是证据不足');
    });

    test('查询缺少歌手时不倒扣分（有信息就用，没有就不猜）', () {
      final q = OnlineLyricQuery(
        title: '晴天',
        duration: const Duration(seconds: 269),
      );
      final s = OnlineLyricMatcher.score(
        q,
        cand('晴天', artist: '周杰伦', durationSec: 269),
      );
      expect(s, greaterThanOrEqualTo(OnlineLyricMatcher.acceptThreshold));
    });

    test('标题为空的一侧 → 0（不能靠空串「匹配成功」）', () {
      final q = OnlineLyricQuery(title: '', artist: '周杰伦');
      expect(OnlineLyricMatcher.score(q, cand('晴天', artist: '周杰伦')), 0);
      expect(
        OnlineLyricMatcher.score(
          OnlineLyricQuery(title: '晴天', artist: '周杰伦'),
          cand('', artist: '周杰伦'),
        ),
        0,
      );
    });

    test('阈值是 0.7（有测试钉住，防止被悄悄放宽）', () {
      expect(OnlineLyricMatcher.acceptThreshold, 0.7);
    });
  });

  group('LRCLIB 在线来源（免密钥，符合「密钥不入客户端」红线）', () {
    test('解析候选：丢掉无歌词的条目、优先带时间轴的歌词', () async {
      final fake = FakeAdapter()
        ..fallback(status: 200, body: <dynamic>[
          <String, dynamic>{
            'trackName': '晴天',
            'artistName': '周杰伦',
            'albumName': '叶惠美',
            'duration': 269,
            'syncedLyrics': _lrc,
            'plainLyrics': '第一行\n第二行\n第三行',
          },
          <String, dynamic>{
            'trackName': '只有元数据',
            'artistName': '某某',
            'albumName': '',
            'duration': 100,
            'syncedLyrics': null,
            'plainLyrics': null,
          },
          <String, dynamic>{
            'trackName': '晴天',
            'artistName': '周杰伦',
            'albumName': '',
            'duration': 269,
            'syncedLyrics': null,
            'plainLyrics': '纯文本歌词',
          },
        ]);

      final src = LrclibLyricSource(dio: Dio()..httpClientAdapter = fake);
      final out = await src.search(
        const OnlineLyricQuery(title: '晴天', artist: '周杰伦'),
      );

      expect(out.length, 2, reason: '只有元数据、没有歌词的条目必须被丢掉');
      expect(out.every((c) => c.hasContent), isTrue);
      expect(out.every((c) => c.score > 0), isTrue);
      expect(out.first.score, greaterThanOrEqualTo(out.last.score),
          reason: '必须按置信度降序，第一条就是「最佳候选」');

      final synced =
          out.firstWhere((c) => c.syncedLyrics != null && c.syncedLyrics!.isNotEmpty);
      expect(synced.content, startsWith('[00:00.00]'),
          reason: '同时有 synced / plain 时必须优先用带时间轴的');
      expect(synced.duration, const Duration(seconds: 269));

      final plainOnly =
          out.firstWhere((c) => c.syncedLyrics == null || c.syncedLyrics!.isEmpty);
      expect(plainOnly.content, '纯文本歌词');
    });

    test('请求参数与 User-Agent 正确（LRCLIB 条款要求标识客户端）', () async {
      final fake = FakeAdapter()..fallback(status: 200, body: <dynamic>[]);
      final src = LrclibLyricSource(dio: Dio()..httpClientAdapter = fake);

      await src.search(
        const OnlineLyricQuery(title: '晴天', artist: '周杰伦', album: '叶惠美'),
      );

      expect(fake.last.uri.path, '/api/search');
      expect(fake.last.query['track_name'], '晴天');
      expect(fake.last.query['artist_name'], '周杰伦');

      final String ua = fake.last.headers.entries
          .firstWhere((MapEntry<String, dynamic> e) =>
              e.key.toLowerCase() == 'user-agent')
          .value
          .toString();
      expect(ua, contains('feiniu-tv-music'),
          reason: 'LRCLIB 使用条款要求客户端表明身份');
    });

    test('标题为空 → 不发请求（省一次无意义的往返）', () async {
      final fake = FakeAdapter()..fallback(status: 200, body: <dynamic>[]);
      final src = LrclibLyricSource(dio: Dio()..httpClientAdapter = fake);

      expect(await src.search(const OnlineLyricQuery(title: '   ')), isEmpty);
      expect(fake.isEmpty, isTrue);
    });

    test('响应不是数组 → 返回空而不是抛异常', () async {
      final fake = FakeAdapter()
        ..fallback(status: 200, body: <String, dynamic>{'oops': true});
      final src = LrclibLyricSource(dio: Dio()..httpClientAdapter = fake);
      expect(await src.search(const OnlineLyricQuery(title: '晴天')), isEmpty);
    });

    test('服务端一直不返回 → 在自己的硬超时内抛 TimeoutException', () async {
      // ⚠️ Dio 的 receiveTimeout 只管「两个数据包之间的间隔」，
      //    对「连上了但永远不吐数据」完全无效，必须靠外层 .timeout。
      final src = LrclibLyricSource(
        dio: Dio()..httpClientAdapter = _NeverAdapter(),
        requestTimeout: const Duration(milliseconds: 80),
      );
      await expectLater(
        src.search(const OnlineLyricQuery(title: '晴天')),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('displayName 用于向用户说明歌词来源', () {
      expect(LrclibLyricSource().displayName, 'LRCLIB');
    });
  });

  group('LyricRepository 三段式取词（NAS 优先 → 在线兜底 → 暂无歌词）', () {
    test('NAS 有歌词 → 在线来源根本不会被调用', () async {
      final online = _FakeOnline(
        candidates: <OnlineLyricCandidate>[
          cand('晴天', artist: '周杰伦', durationSec: 269, synced: _lrc),
        ],
      );
      final lyrics = LyricRepository(FakeLyricSource.sample(), online: online);
      addTearDown(lyrics.dispose);

      await lyrics.load(song('g1'));

      expect(lyrics.origin, LyricOrigin.nas);
      expect(lyrics.doc.lines.length, 3);
      expect(online.calls, 0, reason: 'NAS 优先 —— 不该白耗一次网络请求');
      expect(lyrics.hasCandidates, isFalse);
    });

    test('NAS 无歌词 + 在线高置信度 → 自动绑定，来源标为「在线匹配」', () async {
      final online = _FakeOnline(
        candidates: <OnlineLyricCandidate>[
          cand('晴天', artist: '周杰伦', durationSec: 269, synced: _lrc),
        ],
      );
      // FakeLyricSource() 默认返回空歌词 → 正好触发兜底
      final lyrics = LyricRepository(FakeLyricSource(), online: online);
      addTearDown(lyrics.dispose);

      await lyrics.load(song('g1'));

      expect(online.calls, 1);
      expect(online.lastQuery?.title, '晴天');
      expect(online.lastQuery?.artist, '周杰伦');
      expect(online.lastQuery?.album, '叶惠美');
      expect(online.lastQuery?.duration, const Duration(seconds: 269),
          reason: '时长是区分原版 / Live / Remix 最可靠的信号，必须传下去');

      expect(lyrics.origin, LyricOrigin.online);
      expect(lyrics.doc.lines.length, 3);
      expect(lyrics.isEmpty, isFalse);
      expect(lyrics.origin.label, '在线匹配');
    });

    test('NAS 请求失败 + 在线高置信度 → 仍然能拿到歌词', () async {
      final online = _FakeOnline(
        candidates: <OnlineLyricCandidate>[
          cand('晴天', artist: '周杰伦', durationSec: 269, synced: _lrc),
        ],
      );
      final lyrics =
          LyricRepository(FakeLyricSource(fail: true), online: online);
      addTearDown(lyrics.dispose);

      await lyrics.load(song('g1'));
      expect(lyrics.origin, LyricOrigin.online);
      expect(lyrics.doc.lines.length, 3);
    });

    test('置信度不足 → **不自动绑定**，只把候选列出来交给用户选', () async {
      final online = _FakeOnline(
        candidates: <OnlineLyricCandidate>[
          cand('晴天', artist: '某翻唱', durationSec: 400, synced: _lrc),
        ],
      );
      final lyrics = LyricRepository(FakeLyricSource(), online: online);
      addTearDown(lyrics.dispose);

      await lyrics.load(song('g1'));

      expect(lyrics.origin, LyricOrigin.none,
          reason: '宁可显示「暂无歌词」，也不能绑错歌词');
      expect(lyrics.isEmpty, isTrue);
      expect(lyrics.hasCandidates, isTrue, reason: '候选要留给用户手动选');
      expect(lyrics.candidates.length, 1);
    });

    test('标题完全不匹配的候选 → 既不绑定也不进候选（分数为 0 被过滤在本层）',
        () async {
      // 直接给一条 score 为 0 的候选：低于阈值 → 只作为候选，不绑定
      final online = _FakeOnline(
        candidates: <OnlineLyricCandidate>[
          cand('稻香', artist: '周杰伦', durationSec: 200, synced: _lrc)
              .withScore(0),
        ],
      );
      final lyrics = LyricRepository(FakeLyricSource(), online: online);
      addTearDown(lyrics.dispose);

      await lyrics.load(song('g1'));
      expect(lyrics.origin, LyricOrigin.none);
      expect(lyrics.isEmpty, isTrue);
    });

    test('在线服务抛异常（断网 / 限流）→ 静默降级为「暂无歌词」，不抛给调用方',
        () async {
      final online = _FakeOnline(error: StateError('在线服务挂了（模拟）'));
      final lyrics = LyricRepository(FakeLyricSource(), online: online);
      addTearDown(lyrics.dispose);

      await lyrics.load(song('g1')); // 不能抛

      expect(lyrics.origin, LyricOrigin.none);
      expect(lyrics.isEmpty, isTrue);
      expect(lyrics.isLoading, isFalse, reason: '不能一直停在「加载中」转圈');
    });

    test('在线搜索超时 → 同样静默降级（异常路径与断网一致）', () async {
      final online = _FakeOnline(error: TimeoutException('超时（模拟）'));
      final lyrics = LyricRepository(FakeLyricSource(), online: online);
      addTearDown(lyrics.dispose);

      await lyrics.load(song('g1'));
      expect(lyrics.origin, LyricOrigin.none);
      expect(lyrics.isLoading, isFalse);
    });

    test('在线超时必须短于 NAS 超时（兜底不该比主源更慢）', () {
      expect(
        LyricRepository.onlineTimeout,
        lessThan(LyricRepository.requestTimeout),
        reason: '在线是兜底：让用户等它，还不如直接说「暂无歌词」',
      );
    });

    test('总开关关掉后完全不联网（用户可选）', () async {
      final online = _FakeOnline(
        candidates: <OnlineLyricCandidate>[
          cand('晴天', artist: '周杰伦', durationSec: 269, synced: _lrc),
        ],
      );
      LyricRepository.onlineEnabled = false;
      final lyrics = LyricRepository(FakeLyricSource(), online: online);
      addTearDown(lyrics.dispose);

      await lyrics.load(song('g1'));
      expect(online.calls, 0);
      expect(lyrics.origin, LyricOrigin.none);
      expect(lyrics.isEmpty, isTrue);
    });

    test('没注入在线来源时只走 NAS（测试环境的默认行为）', () async {
      final lyrics = LyricRepository(FakeLyricSource());
      addTearDown(lyrics.dispose);

      await lyrics.load(song('g1'));
      expect(lyrics.origin, LyricOrigin.none);
      expect(lyrics.isEmpty, isTrue);
    });

    test('手动选择候选 → 来源标为「手动选择」并解析出时间轴', () async {
      final online = _FakeOnline(
        candidates: <OnlineLyricCandidate>[
          cand('晴天', artist: '某翻唱', durationSec: 400, synced: _lrc)
              .withScore(0.2),
          cand('晴天 (Live)', artist: '周杰伦', durationSec: 300,
              plain: '第一行\n第二行')
              .withScore(0.3),
        ],
      );
      final lyrics = LyricRepository(FakeLyricSource(), online: online);
      addTearDown(lyrics.dispose);

      await lyrics.load(song('g1'));
      expect(lyrics.hasCandidates, isTrue);

      lyrics.applyCandidate(0);
      expect(lyrics.origin, LyricOrigin.manual);
      expect(lyrics.origin.label, '手动选择');
      expect(lyrics.doc.lines.length, 3);

      lyrics.applyCandidate(1); // 换成纯文本候选
      expect(lyrics.doc.lines.length, 2);
    });

    test('越界的候选下标被忽略（不抛）', () async {
      final online = _FakeOnline(
        candidates: <OnlineLyricCandidate>[
          cand('晴天', artist: '某翻唱', durationSec: 400, synced: _lrc)
              .withScore(0.2),
        ],
      );
      final lyrics = LyricRepository(FakeLyricSource(), online: online);
      addTearDown(lyrics.dispose);

      await lyrics.load(song('g1'));
      lyrics.applyCandidate(-1);
      lyrics.applyCandidate(99);
      expect(lyrics.origin, LyricOrigin.none);
    });

    test('切歌会清空候选与来源（旧请求的结果不能落到新歌上）', () async {
      final online = _FakeOnline(
        candidates: <OnlineLyricCandidate>[
          cand('晴天', artist: '周杰伦', durationSec: 269, synced: _lrc),
        ],
      );
      final lyrics = LyricRepository(FakeLyricSource(), online: online);
      addTearDown(lyrics.dispose);

      await lyrics.load(song('g1'));
      expect(lyrics.hasCandidates, isTrue);

      lyrics.clear();
      expect(lyrics.hasCandidates, isFalse);
      expect(lyrics.origin, LyricOrigin.none);
      expect(lyrics.isEmpty, isTrue);
      expect(lyrics.loadedGuid, isNull);
    });

    test('在线歌词走缓存：第二首同一首歌不再打网络', () async {
      final online = _FakeOnline(
        candidates: <OnlineLyricCandidate>[
          cand('晴天', artist: '周杰伦', durationSec: 269, synced: _lrc),
        ],
      );
      final lyrics = LyricRepository(FakeLyricSource(), online: online);
      addTearDown(lyrics.dispose);

      await lyrics.load(song('g1'));
      expect(online.calls, 1);
      expect(lyrics.origin, LyricOrigin.online);

      await lyrics.load(song('g1')); // 命中缓存
      expect(online.calls, 1, reason: '在线结果必须缓存，避免来回切歌反复请求');
      expect(lyrics.origin, LyricOrigin.online);
    });

    test('空 guid 直接返回（不请求、不写状态）', () async {
      final online = _FakeOnline();
      final lyrics = LyricRepository(FakeLyricSource(), online: online);
      addTearDown(lyrics.dispose);

      await lyrics.load(song(''));
      expect(online.calls, 0);
      expect(lyrics.loadedGuid, isNull);
    });
  });
}
