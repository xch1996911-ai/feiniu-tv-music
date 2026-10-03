import 'genre.dart';
import 'track.dart';

/// 全曲库风格归纳引擎（**纯函数，无 IO，可单测**）。
///
/// ## 分类优先级（需求 §三.2）
///
/// | 级别 | 来源 | 依据 | 置信度 |
/// |---|---|---|---|
/// | a | [GenreSource.manual] | 用户手动确认/修改 | 1.0 |
/// | b | [GenreSource.serverTag] | 歌曲文件或服务端的明确风格标签 | 1.0 |
/// | c | 外部元数据 | **本项目未接入**（无凭据），见下方「能力边界」 | — |
/// | d1 | [GenreSource.albumRule] | 同一专辑内已被确认的风格 | 0.6 |
/// | d2 | [GenreSource.titleRule] | 标题/专辑名里的**明确类型词** | 0.45 |
/// | d3 | [GenreSource.artistRule] | 同歌手其他**已确认**曲目的常见风格 | 0.35 |
/// | — | 无 | 证据不足 → `待分类` | 0 |
///
/// 高优先级**永不被低优先级覆盖**（[GenreSource.rank] 数字越小越强）。
///
/// ## 能力边界（如实声明）
///
/// 需求 §三.2c 允许使用「外部音乐元数据中该曲目/专辑的明确标签」。
/// 本项目**没有配置任何外部元数据服务的凭据**（V4 只接了免密钥的
/// LRCLIB 歌词服务，它不提供风格标签），因此这一级**未实现**，
/// 归纳完全依赖 b + d 三级。这不是「暂时跳过」而是当前能力的真实上界：
/// 没有凭据就不该假装有。相关说明登记在诊断页。
///
/// ## 明确不做的事（需求 §三.3）
/// - 不把 `Live / 现场 / Remastered / 重制 / Acoustic / 原声版` 当风格
///   （见 [GenreRules.versionWords]，这些是版本/编曲信息）；
/// - **不按语言**判定（中文/英文/粤语都不是风格）；
/// - **不按歌手姓名**判定（只按同歌手其他曲目的**已确认**风格传播，
///   这是「有证据的相似性」，不是「看名字猜」）；
/// - **不把缺标签的一律归为「流行」**（那是伪造数据，会让风格页看起来
///   很丰满而实际全是错的）。
class GenreInferencer {
  GenreInferencer._();

  /// 专辑规则最少需要几张「已被确认」的曲目才生效。
  ///
  /// 设为 2 而不是 1：一首歌的标签可能是错的（用户只给一首标了风格），
  /// 至少两首一致才说明这张专辑整体属于该风格。
  static const int albumMinVotes = 2;

  /// 专辑规则：该风格在专辑「已确认」曲目中的占比下限。
  static const double albumDominance = 0.6;

  /// 专辑规则的置信度。
  static const double albumConfidence = 0.6;

  /// 标题/专辑名类型词的置信度。
  static const double titleConfidence = 0.45;

  /// 歌手规则最少需要该歌手有多少首「已确认」曲目。
  static const int artistMinTracks = 3;

  /// 歌手规则：该风格在歌手「已确认」曲目中的占比下限。
  static const double artistDominance = 0.6;

  /// 歌手规则的置信度（三级里最弱）。
  static const double artistConfidence = 0.35;

  /// 归纳结果。
  ///
  /// [byGuid] 只包含**有结论**的曲目；未出现在其中的即「待分类」。
  /// 之所以不塞一个字面量 `待分类` 进去：那样「待分类」会和其他风格一样
  /// 出现在同一层，容易被误当成一种风格。
  static GenreInferenceResult infer(
    List<Track> catalogue, {
    Map<String, List<String>> overrides = const <String, List<String>>{},
  }) {
    final Map<String, List<GenreAssignment>> byGuid =
        <String, List<GenreAssignment>>{};

    // 去重后的曲目（分页合并可能带来重复 guid）。
    final List<Track> tracks = <Track>[];
    final Set<String> seen = <String>{};
    for (final Track t in catalogue) {
      final String key = _keyOf(t);
      if (key.isEmpty || !seen.add(key)) continue;
      tracks.add(t);
    }

    // ── a. 用户手动确认（最高优先级，先落位）
    for (final Track t in tracks) {
      final List<String>? manual = overrides[_keyOf(t)];
      if (manual == null || manual.isEmpty) continue;
      byGuid[_keyOf(t)] = <GenreAssignment>[
        for (final String g in _clean(manual))
          GenreAssignment(
            genre: g,
            source: GenreSource.manual,
            confidence: 1.0,
          ),
      ];
    }

    // ── b. 明确标签（服务端 / 文件）
    for (final Track t in tracks) {
      final String key = _keyOf(t);
      if (byGuid.containsKey(key)) continue; // 手动优先，不参与
      final Set<String> mapped = <String>{};
      for (final String raw in t.genres) {
        mapped.addAll(GenreRules.mapExplicitTag(raw));
      }
      if (mapped.isEmpty) continue;
      byGuid[key] = <GenreAssignment>[
        for (final String g in _sortByUnified(mapped))
          GenreAssignment(
            genre: g,
            source: GenreSource.serverTag,
            confidence: 1.0,
          ),
      ];
    }

    // ── d1. 专辑规则
    final Map<String, List<Track>> albumGroups = <String, List<Track>>{};
    for (final Track t in tracks) {
      albumGroups.putIfAbsent(_albumKeyOf(t), () => <Track>[]).add(t);
    }
    for (final List<Track> group in albumGroups.values) {
      final List<String> votes = <String>[];
      for (final Track t in group) {
        final List<GenreAssignment>? a = byGuid[_keyOf(t)];
        if (a == null) continue;
        // 只用「强来源」投票 —— 递归使用推断结果会让错误自我强化。
        for (final GenreAssignment g in a) {
          if (g.source.rank <= GenreSource.serverTag.rank) votes.add(g.genre);
        }
      }
      final List<String> winners = _winners(votes, albumMinVotes, albumDominance);
      if (winners.isEmpty) continue;
      for (final Track t in group) {
        final String key = _keyOf(t);
        if (byGuid.containsKey(key)) continue; // 已有更强来源
        byGuid[key] = <GenreAssignment>[
          for (final String g in winners)
            GenreAssignment(
              genre: g,
              source: GenreSource.albumRule,
              confidence: albumConfidence,
            ),
        ];
      }
    }

    // ── d2. 标题 / 专辑名的明确类型词
    for (final Track t in tracks) {
      final String key = _keyOf(t);
      if (byGuid.containsKey(key)) continue;
      final Set<String> fromText = <String>{
        ...GenreRules.genresFromText(t.title),
        ...GenreRules.genresFromText(t.album.name),
      };
      if (fromText.isEmpty) continue;
      byGuid[key] = <GenreAssignment>[
        for (final String g in _sortByUnified(fromText))
          GenreAssignment(
            genre: g,
            source: GenreSource.titleRule,
            confidence: titleConfidence,
          ),
      ];
    }

    // ── d3. 歌手规则（最弱）
    final Map<String, List<Track>> artistGroups = <String, List<Track>>{};
    for (final Track t in tracks) {
      for (final String aKey in _artistKeysOf(t)) {
        artistGroups.putIfAbsent(aKey, () => <Track>[]).add(t);
      }
    }
    for (final List<Track> group in artistGroups.values) {
      final List<String> votes = <String>[];
      for (final Track t in group) {
        final List<GenreAssignment>? a = byGuid[_keyOf(t)];
        if (a == null) continue;
        for (final GenreAssignment g in a) {
          // 只统计**原始确认**（手动 / 标签），不含任何推断。
          if (g.source.rank <= GenreSource.serverTag.rank) votes.add(g.genre);
        }
      }
      final List<String> winners =
          _winners(votes, artistMinTracks, artistDominance);
      if (winners.isEmpty) continue;
      for (final Track t in group) {
        final String key = _keyOf(t);
        if (byGuid.containsKey(key)) continue;
        byGuid[key] = <GenreAssignment>[
          for (final String g in winners)
            GenreAssignment(
              genre: g,
              source: GenreSource.artistRule,
              confidence: artistConfidence,
            ),
        ];
      }
    }

    return GenreInferenceResult(
      byGuid: Map<String, List<GenreAssignment>>.unmodifiable(byGuid),
      totalTracks: tracks.length,
    );
  }

  // ── 内部工具 ──────────────────────────────────────────────

  /// 曲目的稳定标识：优先 `guid`，缺失时退回「标题 + 歌手」（与
  /// `LocalLibraryRepository._Bucket` 的去重口径一致）。
  static String _keyOf(Track t) => t.guid.isNotEmpty
      ? t.guid
      : (t.title.isEmpty ? '' : '${t.title}\u0000${t.artistNames}');

  /// 专辑分组标识。
  ///
  /// ⚠️ 与 `LocalLibraryRepository.albumOverviews` 保持一致：
  /// `album.guid` 优先；缺失时用「专辑名 + 首位歌手」——
  /// 只按专辑名会在「不同歌手的同名专辑」（如各种《精选集》）上误合并。
  static String _albumKeyOf(Track t) {
    final String guid = t.album.guid.trim();
    if (guid.isNotEmpty) return 'al:$guid';
    final String name = t.album.name.trim();
    if (name.isEmpty) return 'al:#';
    final String artist =
        t.artists.isEmpty ? '' : t.artists.first.name.trim();
    return 'al:#$name\u0000$artist';
  }

  static List<String> _artistKeysOf(Track t) {
    final List<String> out = <String>[];
    for (final artist in t.artists) {
      final String guid = artist.guid.trim();
      final String name = artist.name.trim();
      if (guid.isNotEmpty) {
        out.add('ar:$guid');
      } else if (name.isNotEmpty) {
        out.add('ar:#$name');
      }
    }
    return out;
  }

  static List<String> _clean(List<String> raw) {
    final Set<String> out = <String>{};
    for (final String g in raw) {
      final String t = g.trim();
      if (t.isEmpty) continue;
      out.add(t);
    }
    return _sortByUnified(out);
  }

  /// 按统一集合的声明顺序排序，未在集合内的排后面（按名称）。
  /// 保证同一份输入永远产出同一顺序 —— 可复现是归纳的基本要求。
  static List<String> _sortByUnified(Iterable<String> genres) {
    final List<String> list = genres.toList();
    list.sort((String a, String b) {
      final int ia = GenreRules.unified.indexOf(a);
      final int ib = GenreRules.unified.indexOf(b);
      if (ia >= 0 && ib >= 0) return ia.compareTo(ib);
      if (ia >= 0) return -1;
      if (ib >= 0) return 1;
      return a.compareTo(b);
    });
    return list;
  }

  /// 从投票里选出「达标」的风格。
  ///
  /// [minVotes]：该风格至少要有几张曲目投它；
  /// [dominance]：它在全部投票里的占比下限。
  static List<String> _winners(
    List<String> votes,
    int minVotes,
    double dominance,
  ) {
    if (votes.isEmpty) return const <String>[];
    final Map<String, int> count = <String, int>{};
    for (final String g in votes) {
      count[g] = (count[g] ?? 0) + 1;
    }
    final int total = votes.length;
    final List<String> out = <String>[
      for (final MapEntry<String, int> e in count.entries)
        if (e.value >= minVotes && e.value / total >= dominance) e.key,
    ];
    return _sortByUnified(out);
  }
}

/// 归纳产物。
class GenreInferenceResult {
  /// 曲目标识 → 风格归属（只含有结论的曲目）。
  final Map<String, List<GenreAssignment>> byGuid;

  /// 参与归纳的**去重后**曲目数。
  final int totalTracks;

  const GenreInferenceResult({
    required this.byGuid,
    required this.totalTracks,
  });

  /// 有结论的曲目数。
  int get classified => byGuid.length;

  /// 待分类曲目数。
  int get unclassified => totalTracks - byGuid.length;

  /// 产出这份结果时使用的规则版本（写进索引，用于判断是否需要重算）。
  int get ruleVersion => GenreRules.version;

  /// 某个风格下的曲目标识。
  List<String> guidsOf(String genre) => <String>[
        for (final MapEntry<String, List<GenreAssignment>> e in byGuid.entries)
          if (e.value.any((GenreAssignment a) => a.genre == genre)) e.key,
      ];

  /// 某个风格是否**全部**由推断得出（概览页据此显示「推断」标识）。
  bool isGenreFullyInferred(String genre) {
    bool any = false;
    for (final List<GenreAssignment> list in byGuid.values) {
      for (final GenreAssignment a in list) {
        if (a.genre != genre) continue;
        any = true;
        if (!a.source.isInferred) return false;
      }
    }
    return any;
  }
}
