import 'package:feiniu_tv_music/domain/album.dart';
import 'package:feiniu_tv_music/domain/artist.dart';
import 'package:feiniu_tv_music/domain/lyric.dart';
import 'package:feiniu_tv_music/domain/track.dart';
import 'package:feiniu_tv_music/repositories/lyric_repository.dart';
import 'package:feiniu_tv_music/services/online_lyric_source.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_lyric_source.dart';

/// 【V5】歌词链路：**「非空」不等于「有效」**（需求 §六.3 / §六.5）。
///
/// ## 这组断言对应的实机现象（图5）
///
/// 播放页歌词区只有一个音乐符号 `♪`。链路是：
/// NAS 的 `lyric/list` 返回了非空的 `list`，里面那条 `text` 只是占位符/空白，
/// 于是 `nasDoc.isNotEmpty` 成立 → **提前 return → 在线兜底永远不跑**，
/// 界面上就只剩一个符号。
///
/// 修法是把判据从「非空」改成「有效」：去掉时间标签后，
/// 统计有信息量的字符（汉字/字母/数字）总数，**≥ 4** 才算有效。
/// 判据放在 `LyricDoc.isUsable`（领域层）+ 仓库的一处收口，
/// UI 完全不需要知道「占位符」这个概念。
void main() {
  Track track() => Track(
        guid: 'g1',
        title: '勇气',
        durationMs: 240000,
        album: const AlbumRef(guid: 'al1', name: '专辑'),
        artists: const <ArtistRef>[ArtistRef(guid: 'ar1', name: '歌手')],
        audioSpec: const AudioSpec(format: 'flac'),
      );

  LyricDoc docOf(String raw) {
    final List<LyricLine> lines = LyricDoc.parseLrc(raw);
    if (lines.isNotEmpty) return LyricDoc(lines: lines);
    return LyricDoc(lines: <LyricLine>[LyricLine(text: raw)]);
  }

  group('§六.3 「有效歌词」的判定', () {
    test('A 纯占位符 / 符号 / 只有时间标签 → 无效', () {
      for (final String raw in <String>[
        '♪',
        '♪♪♪',
        '♫ ♬',
        '· · ·',
        '---',
        '……',
        '[00:00.00]',
        '[00:00.00]\n[00:05.00]\n',
        '   ',
      ]) {
        expect(docOf(raw).isUsable, isFalse,
            reason: '「$raw」没有任何歌词信息，不能算有歌词');
      }
    });

    test('B 真实歌词（中文 / 英文 / 纯文本）→ 有效', () {
      expect(docOf('第一行歌词\n第二行歌词').isUsable, isTrue);
      expect(docOf('We were both young').isUsable, isTrue);
      expect(docOf('纯音乐，请欣赏').isUsable, isTrue,
          reason: '服务端明确告知「纯音乐」是有意义的信息，应当展示');
    });

    test('C 有信息量的字符数统计口径（符号与标点不计）', () {
      expect(LyricDoc.informativeCharCount('♪♪♪♪♪♪'), 0);
      expect(LyricDoc.informativeCharCount('你好'), 2);
      expect(LyricDoc.informativeCharCount('[00:12.34]你好呀'), 3);
      expect(LyricDoc.informativeCharCount('ab12'), 4);
      expect(LyricDoc.informativeCharCount('（，。！？）'), 0);
    });
  });

  group('§六.3 NAS 占位符不再阻断在线兜底', () {
    test('D NAS 只回 ♪ 时判为无歌词（不提前结束）', () async {
      final LyricRepository repo = LyricRepository(
        FakeLyricSource(doc: docOf('♪')),
      );
      await repo.load(track());

      expect(repo.doc.isEmpty, isTrue,
          reason: 'NAS 的占位符不能让流程提前 return');
      expect(repo.origin, LyricOrigin.none);
      expect(repo.isEmpty, isTrue);
      repo.dispose();
    });

    test('E NAS 只回占位符 → 在线匹配真正被执行', () async {
      final _RecordingOnline online = _RecordingOnline(<OnlineLyricCandidate>[
        OnlineLyricCandidate(
          title: '勇气',
          artist: '歌手',
          album: '专辑',
          duration: const Duration(seconds: 240),
          syncedLyrics: '[00:01.00]终於做了这个决定\n[00:05.00]别人怎么说我不理\n',
          score: 0,
          source: 'test',
        ),
      ]);
      final LyricRepository repo = LyricRepository(
        FakeLyricSource(doc: docOf('♪')),
        online: online,
      );
      await repo.load(track());

      expect(online.searchCount, 1,
          reason: 'NAS 占位符必须触发在线兜底 —— 这正是 V4 缺失的一步');
      expect(repo.origin, LyricOrigin.online);
      expect(repo.doc.lines.length, 2);
      repo.dispose();
    });

    test('F NAS 有真实歌词时**不**联网（省流量、也更快）', () async {
      final _RecordingOnline online = _RecordingOnline(<OnlineLyricCandidate>[]);
      final LyricRepository repo = LyricRepository(
        FakeLyricSource(doc: docOf('[00:00.00]第一行歌词\n[00:05.00]第二行歌词')),
        online: online,
      );
      await repo.load(track());

      expect(repo.origin, LyricOrigin.nas);
      expect(online.searchCount, 0, reason: 'NAS 有效就不该再去联网');
      repo.dispose();
    });

    test('G 在线候选只有占位符时也不绑定，退回「暂无歌词」', () async {
      final _RecordingOnline online = _RecordingOnline(<OnlineLyricCandidate>[
        OnlineLyricCandidate(
          title: '勇气',
          artist: '歌手',
          album: '专辑',
          duration: const Duration(seconds: 240),
          syncedLyrics: '♪♪♪',
          score: 0,
          source: 'test',
        ),
      ]);
      final LyricRepository repo = LyricRepository(
        FakeLyricSource(doc: LyricDoc.empty),
        online: online,
      );
      await repo.load(track());

      expect(repo.doc.isEmpty, isTrue, reason: '占位符候选不能被当成歌词绑定');
      expect(repo.origin, LyricOrigin.none);
      repo.dispose();
    });

    test('H 缓存命中的无效歌词不会被复用', () async {
      final LyricRepository repo = LyricRepository(
        FakeLyricSource(doc: docOf('♪')),
      );
      await repo.load(track());
      await repo.load(track()); // 第二次走缓存路径
      expect(repo.doc.isEmpty, isTrue);
      repo.dispose();
    });
  });
}

/// 记录调用次数的在线源替身。
class _RecordingOnline implements OnlineLyricSource {
  _RecordingOnline(this.candidates);

  final List<OnlineLyricCandidate> candidates;
  int searchCount = 0;

  @override
  String get displayName => 'test';

  @override
  Future<List<OnlineLyricCandidate>> search(OnlineLyricQuery query) async {
    searchCount++;
    return candidates;
  }
}
