import 'package:feiniu_tv_music/domain/album.dart';
import 'package:feiniu_tv_music/domain/artist.dart';
import 'package:feiniu_tv_music/domain/genre.dart';
import 'package:feiniu_tv_music/domain/genre_inferencer.dart';
import 'package:feiniu_tv_music/domain/track.dart';
import 'package:feiniu_tv_music/repositories/local_library_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// 【V5】风格自动归纳的规则回归（需求 §三.1–§三.6）。
///
/// ## 这组断言真正要防的是什么
///
/// 实机曲库里 `Track.genres` **全是空数组**，所以 V4 的风格页永远停在
/// 「暂无风格标签」的空态。V5 引入归纳之后，**最大的风险不是「归纳不出来」，
/// 而是「归纳错了还很自信」**：
/// - 把《Rocket Man》按标题里的 `rock` 判成摇滚；
/// - 把 `Live` / `Remastered` / `原声版` 这种版本信息当成风格；
/// - 把中文歌全归进「流行」来让页面看起来饱满。
///
/// 后两种是需求明文禁止的，第一种是我在实现时专门做了词元化处理防住的
/// （见 `GenreRules.genresFromText` 的注释）。
void main() {
  Track track(
    String guid, {
    String? title,
    String genre = '',
    String albumGuid = 'al1',
    String albumName = '专辑',
    String artistGuid = 'ar1',
    String artistName = '歌手',
  }) {
    return Track(
      guid: guid,
      title: title ?? '曲目 $guid',
      durationMs: 180000,
      album: AlbumRef(guid: albumGuid, name: albumName),
      artists: <ArtistRef>[ArtistRef(guid: artistGuid, name: artistName)],
      genres: genre.isEmpty ? const <String>[] : <String>[genre],
      audioSpec: const AudioSpec(format: 'flac'),
    );
  }

  group('§三.1 统一风格集合与标签映射', () {
    test('A 英文/中文/大小写/连字符写法都映射到同一个统一风格', () {
      for (final String raw in <String>[
        'Rock',
        'rock',
        'ROCK MUSIC',
        '摇滚',
        '摇滚乐',
        'alternative rock',
        'Indie-Rock',
      ]) {
        expect(GenreRules.mapExplicitTag(raw), contains('摇滚'),
            reason: '「$raw」应映射到统一集合里的「摇滚」');
      }
      expect(GenreRules.mapExplicitTag('R&B'), contains('R&B/灵魂'));
      expect(GenreRules.mapExplicitTag('hip hop'), contains('嘻哈/说唱'));
      expect(GenreRules.mapExplicitTag('Synthpop'),
          containsAll(<String>['流行', '电子']),
          reason: 'Synthpop 同时属于流行与电子（多风格）');
    });

    test('B 映射不上的**明确标签**保留原样，不丢数据也不硬塞', () {
      expect(GenreRules.mapExplicitTag('蒙古长调'), <String>['蒙古长调']);
    });
  });

  group('§三.3 版本词与语言/姓名不得当风格', () {
    test('C Live / 现场 / Remastered / 原声版 单独出现时不算风格证据', () {
      for (final String raw in <String>[
        'Live',
        '现场',
        'Remastered',
        '重制版',
        'Acoustic',
        '原声版',
        'Unplugged',
        'Demo',
        'Radio Edit',
      ]) {
        expect(GenreRules.isPureVersionWord(raw), isTrue, reason: raw);
        expect(GenreRules.mapExplicitTag(raw), isEmpty,
            reason: '「$raw」是版本/编曲信息，不能当风格');
      }
    });

    test('D 标题里的 Live / 原声版 不产生任何风格', () {
      final GenreInferenceResult r = GenreInferencer.infer(<Track>[
        track('t1', title: '勇气 (Live)'),
        track('t2', title: '遇见 (原声版)'),
        track('t3', title: '后来 (Remastered 2020)'),
      ]);
      expect(r.byGuid, isEmpty, reason: '版本词不该产生风格结论');
      expect(r.unclassified, 3);
    });

    test('E 标题里的词按「词」匹配，不做子串包含（防误判）', () {
      // Rocket 含 "rock"、Ghost 含 "ost"、Brand New 含 "rand"
      final GenreInferenceResult r = GenreInferencer.infer(<Track>[
        track('t1', title: 'Rocket Man'),
        track('t2', title: 'Ghost'),
        track('t3', title: 'Brand New Day'),
      ]);
      expect(r.byGuid, isEmpty,
          reason: '这些标题里的字母组合不是风格词，绝不能判成摇滚/原声带/R&B');

      // 真正的独立词才命中
      final GenreInferenceResult ok = GenreInferencer.infer(<Track>[
        track('t4', title: '摇滚练习曲', albumName: '爵士入门'),
      ]);
      expect(ok.byGuid['t4']!.map((GenreAssignment a) => a.genre),
          containsAll(<String>['摇滚', '爵士']));
    });

    test('F 语言与歌手姓名绝不参与判定', () {
      final GenreInferenceResult r = GenreInferencer.infer(<Track>[
        track('t1', title: '勇气', artistName: '摇滚乐队'),
        track('t2', title: 'Courage', artistName: 'The Jazz Trio'),
      ]);
      expect(r.byGuid, isEmpty,
          reason: '中文/英文是语言属性，歌手名字也不是风格 —— 都不能硬分');
    });
  });

  group('§三.2 优先级与传播', () {
    test('G 专辑内已确认的风格传播给同专辑其他曲目（较低置信度）', () {
      final GenreInferenceResult r = GenreInferencer.infer(<Track>[
        track('t1', genre: '摇滚', albumGuid: 'alA'),
        track('t2', genre: 'Rock', albumGuid: 'alA'),
        track('t3', albumGuid: 'alA'), // 无标签
      ]);
      final List<GenreAssignment>? a = r.byGuid['t3'];
      expect(a, isNotNull, reason: '专辑内 2 首一致 → 可传播');
      expect(a!.first.genre, '摇滚');
      expect(a.first.source, GenreSource.albumRule);
      expect(a.first.confidence, lessThan(1.0), reason: '推断必须低于原始标签');
      expect(a.first.source.isInferred, isTrue);
    });

    test('H 专辑内只有 1 首有标签时不传播（证据不足进「待分类」）', () {
      final GenreInferenceResult r = GenreInferencer.infer(<Track>[
        track('t1', genre: '爵士', albumGuid: 'alB'),
        track('t2', albumGuid: 'alB'),
      ]);
      expect(r.byGuid.containsKey('t2'), isFalse,
          reason: '一首歌的标签不足以代表整张专辑');
      expect(r.unclassified, 1);
    });

    test('I 同一歌手其他已确认曲目的常见风格可作最弱辅助', () {
      final GenreInferenceResult r = GenreInferencer.infer(<Track>[
        track('t1', genre: '民谣', artistGuid: 'arX', albumGuid: 'a1'),
        track('t2', genre: '民谣', artistGuid: 'arX', albumGuid: 'a2'),
        track('t3', genre: 'Folk', artistGuid: 'arX', albumGuid: 'a3'),
        track('t4', artistGuid: 'arX', albumGuid: 'a4'),
      ]);
      final List<GenreAssignment>? a = r.byGuid['t4'];
      expect(a, isNotNull);
      expect(a!.first.source, GenreSource.artistRule);
      expect(a.first.confidence, lessThan(GenreInferencer.albumConfidence));
    });

    test('J 手动确认优先级最高，且自动归纳永不覆盖', () {
      final GenreInferenceResult r = GenreInferencer.infer(
        <Track>[
          track('t1', genre: '古典'),
          track('t2', genre: '古典'),
          track('t3', genre: '古典'),
        ],
        overrides: <String, List<String>>{
          't1': <String>['电子', '嘻哈/说唱'],
        },
      );
      final List<GenreAssignment> a = r.byGuid['t1']!;
      expect(a.map((GenreAssignment g) => g.genre),
          containsAll(<String>['电子', '嘻哈/说唱']));
      expect(a.every((GenreAssignment g) => g.source == GenreSource.manual), isTrue);
      expect(a.first.confidence, 1.0);
      // t2/t3 仍是原始标签（手动只管它自己那首）
      expect(r.byGuid['t2']!.first.source, GenreSource.serverTag);
    });

    test('K 一首歌可以属于多个风格（合唱/多标签）', () {
      final GenreInferenceResult r = GenreInferencer.infer(<Track>[
        Track(
          guid: 't1',
          title: '混搭',
          durationMs: 1000,
          album: const AlbumRef(guid: 'al1', name: '专辑'),
          artists: const <ArtistRef>[],
          genres: const <String>['rock', 'jazz', 'electronic'],
          audioSpec: const AudioSpec(),
        ),
      ]);
      expect(r.byGuid['t1']!.length, 3);
    });
  });

  group('§三.4 概览与「待分类」', () {
    test('L 无标签曲库：全部进「待分类」，绝不伪造「流行」或「未知风格」', () {
      final List<Track> all = <Track>[
        for (int i = 1; i <= 12; i++)
          track('t$i', title: '曲目 $i', albumName: '专辑 ${i ~/ 3}'),
      ];
      final GenreInferenceResult r = GenreInferencer.infer(all);
      expect(r.classified, 0);
      expect(r.unclassified, 12);

      final LocalLibraryRepository local = LocalLibraryRepository();
      final List<LibraryOverview> overviews =
          local.genreOverviewsOf(all, inference: r);
      expect(overviews.length, 1);
      expect(overviews.first.title, GenreRules.unclassified);
      expect(overviews.first.trackCount, 12);
      expect(overviews.first.tracks.length, 12,
          reason: '「待分类」必须带真实曲目列表，用户才能点进去手动确认');
      expect(
        overviews.any((LibraryOverview o) => o.title == '流行'),
        isFalse,
        reason: '把缺标签的歌曲默认归为流行是伪造数据',
      );
      expect(
        overviews.any((LibraryOverview o) => o.title.contains('未知')),
        isFalse,
      );
      local.dispose();
    });

    test('M 混合场景：风格桶 + 待分类桶，且标出「推断」', () {
      final List<Track> all = <Track>[
        track('t1', genre: '摇滚', albumGuid: 'a1'),
        track('t2', genre: '摇滚', albumGuid: 'a1'),
        track('t3', albumGuid: 'a1'), // 由专辑推断
        track('t4', albumGuid: 'a2'), // 无从判断
      ];
      final GenreInferenceResult r = GenreInferencer.infer(all);
      final LocalLibraryRepository local = LocalLibraryRepository();
      final List<LibraryOverview> overviews =
          local.genreOverviewsOf(all, inference: r);

      final LibraryOverview rock = overviews
          .firstWhere((LibraryOverview o) => o.title == '摇滚');
      expect(rock.trackCount, 3);
      expect(rock.inferred, isFalse,
          reason: '有原始标签参与时不该整类标成「推断」');

      final LibraryOverview pending = overviews
          .firstWhere((LibraryOverview o) => o.title == GenreRules.unclassified);
      expect(pending.trackCount, 1);
      expect(overviews.last.title, GenreRules.unclassified,
          reason: '「待分类」永远沉底');
      local.dispose();
    });

    test('N 全部靠推断得出的风格会被标记为 inferred', () {
      final List<Track> all = <Track>[
        // 专辑内 2 首有原始标签 → 第 3 首是推断；
        // 但这里用「只有推断结果」的曲目集合来验证标记逻辑
        track('t1', albumGuid: 'a1', title: '摇滚夜'),
      ];
      final GenreInferenceResult r = GenreInferencer.infer(all);
      expect(r.byGuid['t1']!.first.source, GenreSource.titleRule);
      expect(r.isGenreFullyInferred('摇滚'), isTrue);
    });

    test('O 规则版本随结果一起产出（供索引判断是否需要重算）', () {
      final GenreInferenceResult r = GenreInferencer.infer(<Track>[]);
      expect(r.ruleVersion, GenreRules.version);
      expect(GenreRules.version, greaterThan(0));
    });
  });
}
