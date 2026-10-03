import 'pinyin_service.dart';
import 'text_norm.dart';
import 'track.dart';

/// 命中发生的字段。
enum SearchField { title, artist, album }

/// 命中的**读法强度**：原文 > 拼音 > 首字母 > 模糊。
///
/// 需求（拼音模糊搜索 §3）要求「完全匹配优先于前缀匹配，
/// 前缀匹配优先于包含匹配」「歌名匹配优先于歌手匹配，歌手匹配优先于专辑匹配」，
/// 并要求「模糊匹配（编辑距离 1）仅在效果明显且可开启时提供，
/// 默认不应该让模糊匹配压过精确匹配」。因此这里把两件事**拆开**表达：
/// - [MatchStrength]：命中的是原文、拼音还是首字母；
/// - [MatchPosition]：命中在字段的开头（完全/前缀）还是中间（包含）。
///
/// 打分时强度级差（100）远大于字段加成（10~40），
/// 于是「同强度内先比位置、再比字段」永远成立，
/// 字段加成绝不会把"包含"抬到"完全"上面。
enum MatchStrength {
  /// 用户输入的字**真的出现在**原文字段里（含中英混排的字面命中）。
  original,

  /// 命中整段/部分拼音（`zhoujielun`、`zhoujie`）。
  pinyin,

  /// 命中首字母（`zjl`）。
  initials,

  /// 编辑距离 ≤1 的模糊命中（默认只在前面的结果很少时才启用）。
  fuzzy,
}

/// 命中在字段里的位置。
enum MatchPosition { exact, prefix, contains }

/// 一次字段命中的结果（字段内的**归一化下标**区间，左闭右开）。
class FieldMatch {
  const FieldMatch({
    required this.strength,
    required this.position,
    required this.start,
    required this.end,
  });

  final MatchStrength strength;
  final MatchPosition position;

  /// 在归一化文本里的起始 rune 下标。
  final int start;

  /// 结束 rune 下标（不含）。
  final int end;

  bool get isExact => position == MatchPosition.exact;
}

/// 一条搜索命中：曲目 + 命中字段 + 强度/位置 + 分数。
class SearchHit {
  const SearchHit({
    required this.track,
    required this.field,
    required this.match,
    required this.score,
    required this.order,
  });

  final Track track;
  final SearchField field;
  final FieldMatch match;
  final int score;

  /// 该曲目在曲库里的原始序号 —— 排序的最终 tiebreak。
  ///
  /// ⚠️ 需求明确禁止"每次搜索排序不同"。分数相同时按曲库原始顺序排列，
  /// **不**引入任何随机因素，因此同一查询在同一索引上结果完全可复现。
  final int order;
}

/// 歌手 / 专辑这类"实体"命中。
///
/// 需求 §7：「结果按类型分组展示（歌曲、歌手、专辑），
/// 歌手/专辑点击后打开对应歌曲列表」。
class EntityHit {
  const EntityHit({
    required this.name,
    required this.key,
    required this.coverId,
    required this.trackCount,
    required this.sample,
    required this.match,
    required this.score,
  });

  /// 展示名（原文，不归一化）。
  final String name;

  /// 稳定标识（歌手 guid / 专辑 guid；缺失时退回名字）。
  final String key;

  final String? coverId;

  /// 该实体在**已索引曲库**里的曲目数。
  final int trackCount;

  /// 代表曲目（用于点开后的列表 / 封面兜底）。
  final Track? sample;

  final FieldMatch match;
  final int score;

  /// 构造「实体池」种子。
  ///
  /// ⚠️ 种子里的 [match] / [score] 是**占位值**：分数取决于用户输入，
  /// 只能在查询时算（见 `SearchIndex._queryEntities`）。
  /// 把它做成命名构造而不是让调用方乱填，是为了避免"种子里的分数
  /// 被误当成真实分数渲染出来"。
  EntityHit.seed({
    required this.name,
    required this.key,
    required this.coverId,
    required this.trackCount,
    required this.sample,
  })  : match = const FieldMatch(
          strength: MatchStrength.original,
          position: MatchPosition.contains,
          start: 0,
          end: 0,
        ),
        score = 0;
}

/// 一次查询的完整结果。
class SearchResults {
  const SearchResults({
    required this.query,
    required this.songs,
    required this.artists,
    required this.albums,
    required this.totalSongs,
    required this.indexedTracks,
    required this.indexComplete,
    required this.fuzzyUsed,
  });

  static const SearchResults empty = SearchResults(
    query: '',
    songs: <SearchHit>[],
    artists: <EntityHit>[],
    albums: <EntityHit>[],
    totalSongs: 0,
    indexedTracks: 0,
    indexComplete: false,
    fuzzyUsed: false,
  );

  final String query;
  final List<SearchHit> songs;
  final List<EntityHit> artists;
  final List<EntityHit> albums;

  /// 命中总数（截断前）。
  final int totalSongs;

  /// 本次检索覆盖的曲目数（必须如实展示给用户，需求 §1）。
  final int indexedTracks;

  /// 索引是否已覆盖全库。
  final bool indexComplete;

  /// 是否用到了模糊匹配（用于 UI 提示"结果含近似匹配"）。
  final bool fuzzyUsed;

  bool get isEmpty => songs.isEmpty && artists.isEmpty && albums.isEmpty;
}

/// 单条曲目的索引项（三个字段各一份对齐读法）。
class SearchDoc {
  const SearchDoc({
    required this.track,
    required this.order,
    required this.title,
    required this.artist,
    required this.album,
    required this.versionTags,
  });

  final Track track;
  final int order;

  final AlignedText title;
  final AlignedText artist;
  final AlignedText album;

  /// 识别到的版本词（不参与打分，供未来筛选）。
  final List<String> versionTags;

  AlignedText fieldOf(SearchField f) => switch (f) {
        SearchField.title => title,
        SearchField.artist => artist,
        SearchField.album => album,
      };
}

/// 本地搜索索引：**完整的曲库索引**之上再叠一层"可检索键"。
///
/// ## 与曲库索引的关系（不另起一套数据源）
/// 需求（拼音模糊搜索 §6）要求"新增的搜索能力必须继续复用现有架构，
/// 不能另起一套平行的曲库数据源"。
/// 因此 [SearchIndex] **不持有自己的曲目池**：它逐条引用
/// `LibraryRepository` 已经整理好的同一个 `Track` 对象，
/// 只额外保存"检索键"（归一化文本 + 拼音 + 首字母）。
/// 曲库刷新后索引按 guid 复用未变化条目的键，只重算变化的那些。
///
/// ## 打分模型
/// 见 [MatchStrength] 的说明。分数为
/// `强度基数(300~1000) + 位置基数(0~100) + 字段加成(10~40)`，
/// 级差远大于加成，因此不会出现"歌手完全匹配压过歌名完全匹配"这种反直觉结果。
class SearchIndex {
  SearchIndex({
    required List<SearchDoc> docs,
    required List<EntityHit> artistSeeds,
    required List<EntityHit> albumSeeds,
  })  : _docs = docs,
        _artistSeeds = artistSeeds,
        _albumSeeds = albumSeeds;

  final List<SearchDoc> _docs;

  /// 歌手/专辑的"实体池"（不含分数，分数在每次查询时计算）。
  final List<EntityHit> _artistSeeds;
  final List<EntityHit> _albumSeeds;

  /// 空索引（尚未整理曲库）。
  ///
  /// ⚠️ 是 `static final` 而**不是** `static const` —— `SearchIndex` 持有
  /// `List`，构造它不是常量表达式（曾经写成 `const` 直接编译不过）。
  static final SearchIndex emptyIndex = SearchIndex(
    docs: <SearchDoc>[],
    artistSeeds: <EntityHit>[],
    albumSeeds: <EntityHit>[],
  );

  /// 是不是"空索引"（尚未整理曲库）。UI 据此显示进度而不是"没找到"。
  bool get isEmpty => _docs.isEmpty;

  int get length => _docs.length;

  List<SearchDoc> get docs => List<SearchDoc>.unmodifiable(_docs);

  // ── 打分常量（集中在这里，便于调参与测试断言）──────────────

  static const int _strengthOriginal = 900;
  static const int _strengthPinyin = 600;
  static const int _strengthInitials = 400;
  static const int _strengthFuzzy = 200;

  static const int _posExact = 100;
  static const int _posPrefix = 50;
  static const int _posContains = 0;

  static const int _fieldTitle = 40;
  static const int _fieldArtist = 25;
  static const int _fieldAlbum = 10;

  /// 模糊匹配的门槛：**只在前面结果很少的时候才启用**，
  /// 且要求单个关键词足够长（短词的编辑距离 1 几乎等于乱匹配）。
  static const int fuzzyMinTokenLength = 4;
  static const int fuzzyTriggerBelow = 3;

  /// 查询。
  ///
  /// [limit] 上限是歌曲命中数；歌手/专辑各取前 [entityLimit] 个。
  SearchResults query(
    String raw, {
    int limit = 200,
    int entityLimit = 24,
    bool indexComplete = false,
    bool allowFuzzy = true,
  }) {
    final List<String> tokens = TextNorm.tokens(raw);
    if (tokens.isEmpty) {
      return SearchResults(
        query: raw,
        songs: const <SearchHit>[],
        artists: const <EntityHit>[],
        albums: const <EntityHit>[],
        totalSongs: 0,
        indexedTracks: _docs.length,
        indexComplete: indexComplete,
        fuzzyUsed: false,
      );
    }

    final List<SearchHit> songs = <SearchHit>[];
    for (final SearchDoc d in _docs) {
      final SearchHit? hit = _hitOfDoc(d, tokens);
      if (hit != null) songs.add(hit);
    }

    bool fuzzyUsed = false;
    if (allowFuzzy &&
        songs.length < fuzzyTriggerBelow &&
        tokens.every((String t) => t.length >= fuzzyMinTokenLength)) {
      fuzzyUsed = _appendFuzzy(songs, tokens, entityLimit);
    }

    // ⚠️ 确定性排序：分数降序 → 曲库原始顺序升序。
    //    绝不用不稳定排序，否则同一查询两次结果顺序会变（需求 §5 明令禁止）。
    songs.sort((SearchHit a, SearchHit b) {
      final int c = b.score.compareTo(a.score);
      return c != 0 ? c : a.order.compareTo(b.order);
    });

    final int total = songs.length;
    final List<SearchHit> capped =
        songs.length > limit ? songs.sublist(0, limit) : songs;

    final List<EntityHit> artists =
        _queryEntities(_artistSeeds, tokens, entityLimit);
    final List<EntityHit> albums =
        _queryEntities(_albumSeeds, tokens, entityLimit);

    return SearchResults(
      query: raw,
      songs: capped,
      artists: artists,
      albums: albums,
      totalSongs: total,
      indexedTracks: _docs.length,
      indexComplete: indexComplete,
      fuzzyUsed: fuzzyUsed,
    );
  }

  // ── 单条曲目的匹配 ─────────────────────────────────────────

  SearchHit? _hitOfDoc(SearchDoc d, List<String> tokens) {
    int total = 0;
    SearchField? bestField;
    FieldMatch? bestMatch;
    int worstScore = 1 << 30;

    for (final String t in tokens) {
      SearchField? f;
      FieldMatch? m;
      int bestScore = -1;
      for (final SearchField cand in SearchField.values) {
        final FieldMatch? fm = matchField(d.fieldOf(cand), t);
        if (fm == null) continue;
        final int s = scoreOf(cand, fm);
        if (s > bestScore) {
          bestScore = s;
          f = cand;
          m = fm;
        }
      }
      // 需求 §3：多个关键词之间默认 AND —— 任何一个关键词无命中就整条丢弃。
      if (f == null || m == null) return null;
      total += bestScore;
      if (bestScore < worstScore) {
        worstScore = bestScore;
        bestField = f;
        bestMatch = m;
      }
    }
    if (bestField == null || bestMatch == null) return null;
    return SearchHit(
      track: d.track,
      field: bestField,
      match: bestMatch,
      score: total,
      order: d.order,
    );
  }

  /// 实体（歌手/专辑）命中。
  List<EntityHit> _queryEntities(
    List<EntityHit> seeds,
    List<String> tokens,
    int limit,
  ) {
    final List<EntityHit> out = <EntityHit>[];
    for (final EntityHit e in seeds) {
      final AlignedText aligned = _entityText(e);
      int total = 0;
      FieldMatch? best;
      int worst = 1 << 30;
      bool ok = true;
      for (final String t in tokens) {
        final FieldMatch? m = matchField(aligned, t);
        if (m == null) {
          ok = false;
          break;
        }
        final int s = _strengthBase(m.strength) + _positionBase(m.position);
        total += s;
        if (s < worst) {
          worst = s;
          best = m;
        }
      }
      if (!ok || best == null) continue;
      out.add(EntityHit(
        name: e.name,
        key: e.key,
        coverId: e.coverId,
        trackCount: e.trackCount,
        sample: e.sample,
        match: best,
        score: total,
      ));
    }
    out.sort((EntityHit a, EntityHit b) {
      final int c = b.score.compareTo(a.score);
      if (c != 0) return c;
      final int n = b.trackCount.compareTo(a.trackCount);
      return n != 0 ? n : a.name.compareTo(b.name);
    });
    return out.length > limit ? out.sublist(0, limit) : out;
  }

  // 实体池的对齐文本按 key 缓存（同一实体在多次查询里反复用到）。
  final Map<String, AlignedText> _entityCache = <String, AlignedText>{};

  AlignedText _entityText(EntityHit e) => _entityCache.putIfAbsent(
        '${e.key}\u0000${e.name}',
        () => PinyinService.align(TextNorm.key(e.name)),
      );

  /// 分数 = 强度基数 + 位置基数 + 字段加成。
  static int scoreOf(SearchField field, FieldMatch m) =>
      _strengthBase(m.strength) +
      _positionBase(m.position) +
      _fieldBase(field);

  static int _strengthBase(MatchStrength s) => switch (s) {
        MatchStrength.original => _strengthOriginal,
        MatchStrength.pinyin => _strengthPinyin,
        MatchStrength.initials => _strengthInitials,
        MatchStrength.fuzzy => _strengthFuzzy,
      };

  static int _positionBase(MatchPosition p) => switch (p) {
        MatchPosition.exact => _posExact,
        MatchPosition.prefix => _posPrefix,
        MatchPosition.contains => _posContains,
      };

  static int _fieldBase(SearchField f) => switch (f) {
        SearchField.title => _fieldTitle,
        SearchField.artist => _fieldArtist,
        SearchField.album => _fieldAlbum,
      };

  // ── 模糊匹配（默认低优先级）────────────────────────────────

  /// 追加"轻微拼写错误"的候选（需求 §2 第 8 条）。
  ///
  /// 只在**正常结果很少**时启用，且要求查询词足够长 ——
  /// 短词的编辑距离 1 基本上等于乱匹配（`abc` 能命中半个曲库）。
  /// 命中的是**整个字段**（不做子串近似），因为"子串 + 容错"会让
  /// 噪声爆炸，而用户打错字时通常是把整个词打错。
  ///
  /// 同时比对两种键：
  /// - [AlignedText.full]（`zhoujielun`）—— 覆盖全拼打错；
  /// - [AlignedText.initialsFlat]（`zjl`）—— 覆盖首字母打错。
  bool _appendFuzzy(
    List<SearchHit> songs,
    List<String> tokens,
    int limit,
  ) {
    // 多关键词场景不做近似（AND 语义下"每个词都近似"几乎必然是噪声）。
    if (tokens.length != 1) return false;
    final String token = tokens.first;

    final Set<String> already =
        <String>{for (final SearchHit h in songs) h.track.guid};
    bool used = false;
    for (final SearchDoc d in _docs) {
      if (already.contains(d.track.guid)) continue;
      for (final SearchField f in SearchField.values) {
        final AlignedText a = d.fieldOf(f);
        if (a.isEmpty) continue;
        int dist = _distance(token, a.full);
        if (a.initialsFlat.length != a.full.length) {
          final int di = _distance(token, a.initialsFlat);
          if (di < dist) dist = di;
        }
        if (dist > 1) continue;
        songs.add(SearchHit(
          track: d.track,
          field: f,
          match: const FieldMatch(
            strength: MatchStrength.fuzzy,
            position: MatchPosition.contains,
            start: 0,
            end: 0,
          ),
          score: _strengthFuzzy + _fieldBase(f),
          order: d.order,
        ));
        already.add(d.track.guid);
        used = true;
        break;
      }
      if (songs.length >= limit) break;
    }
    return used;
  }

  /// 有界的编辑距离：返回 `0` / `1` / `999`（≥2 一律折叠成 999）。
  ///
  /// 支持三类"一处编辑"：
  /// - 单处替换（`zhoujielan` ↔ `zhoujielun`）；
  /// - 单处插入/删除（长度差 1）；
  /// - **单处相邻换位**（`zhoujielnu` ↔ `zhoujielun`）—— 这是最常见的手打错误，
  ///   普通 Levenshtein 会把它算成 2 而漏掉，需求 §2 给的例子正是这一类。
  static int _distance(String a, String b) {
    final int la = a.length;
    final int lb = b.length;
    if ((la - lb).abs() > 1) return 999;
    if (a == b) return 0;

    if (la == lb) {
      final List<int> mism = <int>[];
      for (int i = 0; i < la; i++) {
        if (a.codeUnitAt(i) != b.codeUnitAt(i)) {
          mism.add(i);
          if (mism.length > 2) return 999;
        }
      }
      if (mism.length == 1) return 1;
      if (mism.length == 2 && mism[1] == mism[0] + 1) {
        // 相邻两位互换 == 一处"换位"编辑。
        if (a.codeUnitAt(mism[0]) == b.codeUnitAt(mism[1]) &&
            a.codeUnitAt(mism[1]) == b.codeUnitAt(mism[0])) {
          return 1;
        }
      }
      return 999;
    }

    // 长度差 1：短的必须是长的"删掉一个字符"。
    final String s = la < lb ? a : b;
    final String l = la < lb ? b : a;
    int i = 0;
    int j = 0;
    int edits = 0;
    while (i < s.length && j < l.length) {
      if (s.codeUnitAt(i) == l.codeUnitAt(j)) {
        i++;
        j++;
        continue;
      }
      if (++edits > 1) return 999;
      j++;
    }
    edits += l.length - j;
    return edits > 1 ? 999 : edits;
  }

  // ── 匹配核心 ──────────────────────────────────────────────

  /// 在 [doc] 中查找 [token]，返回最"强"的一次命中；找不到返回 null。
  ///
  /// ## 算法：逐字对齐 + 回溯
  ///
  /// 命中的区间必须是 doc 里**连续的一段字**（不跳字，但可以在任意位置开始），
  /// 其中每个字可以用四种方式消费查询：
  /// 1. **整音节**（`jie` 命中「杰」）；
  /// 2. **汉字原位**（`杰` 命中「杰」）；
  /// 3. **音节前缀**（`zh` 命中「周」的 `zhou`）；
  /// 4. **首字母**（`j` 命中「杰」的 `jie`，也即长度 1 的前缀）。
  ///
  /// 因为四种方式并存且长度不同，简单的最长匹配会在
  /// 「周jl」「zjl」「Jay周杰伦」这类混合输入上失效，所以这里用带回溯的
  /// 深度优先搜索，并对 ``(docIndex, queryIndex)`` 做失败记忆化 ——
  /// 同一状态失败与路径无关，因此 memo 是安全的，也把最坏复杂度压到
  /// `O(文档长度 × 查询长度)`。
  ///
  /// ⚠️ 分支顺序 = 优先级：**汉字原位优先**，其次整音节，再其次前缀。
  /// 这样「周杰伦」查「周杰伦」会得到 original/exact（1000 分）
  /// 而不是 pinyin/exact（700 分）—— 用户手打的字出现在原文里，
  /// 理应排在"拼音恰好相同"之前。
  static FieldMatch? matchField(AlignedText doc, String token) {
    if (token.isEmpty || doc.isEmpty) return null;
    // 廉价剪枝：查询不可能比整段拼音更长；且查询里每个字符都必须
    // 出现在文档的"可读字符集"里（ASCII → full，汉字 → 原文）。
    if (!_viable(doc, token)) return null;

    final int n = doc.length;
    final Set<int> dead = <int>{};
    FieldMatch? best;
    for (int start = 0; start < n; start++) {
      final List<int> steps = <int>[];
      final int? end = _dfs(doc, token, 0, start, 0, dead, steps);
      if (end == null) continue;
      final FieldMatch m = _classify(steps, start, end, n);
      if (best == null || _better(m, best)) best = m;
      if (best.isExact &&
          best.strength == MatchStrength.original &&
          best.start == 0) {
        return best; // 已是最优，无需继续
      }
    }
    return best;
  }

  /// 廉价必要条件（**只用于否定**，不会漏掉真实命中）：
  /// - 查询长度不能超过整段拼音长度（连续段最多消费这么多字符）；
  /// - 查询里的 ASCII 字符必须出现在 [AlignedText.full] 里
  ///   （它们只能由音节或非汉字字符提供）；
  /// - 查询里的汉字必须出现在归一化原文里（只能由"汉字原位"提供）。
  static bool _viable(AlignedText doc, String token) {
    if (token.length > doc.full.length) return false;
    for (final int r in token.runes) {
      final String c = String.fromCharCode(r);
      if (TextNorm.isHan(r)) {
        if (!doc.text.contains(c)) return false;
      } else if (!doc.full.contains(c)) {
        return false;
      }
    }
    return true;
  }

  /// 步进类型：0=汉字/原字符，1=整音节，2=音节前缀，3=首字母。
  static int? _dfs(
    AlignedText doc,
    String q,
    int qLen,
    int di,
    int qi,
    Set<int> dead,
    List<int> steps,
  ) {
    if (qi == qLen) return di;
    if (di >= doc.length) return null;
    final int key = di * (qLen + 1) + qi;
    if (!dead.add(key)) return null;

    final String ch = doc.text[di];
    final bool han = TextNorm.isHan(ch.codeUnitAt(0));
    final String syl = doc.syllables[di];

    if (!han) {
      // 非汉字只有一种消费方式：原字符（长度 1）。
      if (q.startsWith(ch, qi)) {
        steps.add(0);
        final int? r = _dfs(doc, q, qLen, di + 1, qi + 1, dead, steps);
        if (r != null) return r;
        steps.removeLast();
      }
      return null;
    }

    // 1) 汉字原位
    if (q.startsWith(ch, qi)) {
      steps.add(0);
      final int? r = _dfs(doc, q, qLen, di + 1, qi + 1, dead, steps);
      if (r != null) return r;
      steps.removeLast();
    }
    // 2) 整音节
    if (syl.isNotEmpty && q.startsWith(syl, qi)) {
      steps.add(1);
      final int? r = _dfs(doc, q, qLen, di + 1, qi + syl.length, dead, steps);
      if (r != null) return r;
      steps.removeLast();
    }
    // 3) 音节前缀（长度从长到短；长度 1 即首字母）
    if (syl.length > 1) {
      final int rest = qLen - qi;
      final int maxLen = rest < syl.length ? rest : syl.length - 1;
      for (int len = maxLen; len >= 1; len--) {
        if (!q.startsWith(syl.substring(0, len), qi)) continue;
        steps.add(len == 1 ? 3 : 2);
        final int? r = _dfs(doc, q, qLen, di + 1, qi + len, dead, steps);
        if (r != null) return r;
        steps.removeLast();
      }
    }
    return null;
  }

  /// 把一次成功的匹配路径归类成「强度 + 位置」。
  ///
  /// [docLength] 是该字段归一化后的**总字数**；只有
  /// `start == 0 && end == docLength`（也就是整段字段被一字不落消费完）
  /// 才算 [MatchPosition.exact]。
  ///
  /// ⚠️ 这里曾经用过一个 `-1` 哨兵值来"占位"，结果是 `exact` 永远判不出来，
  /// 「周杰伦」查「周杰伦」会被降级成 prefix。**必须显式传字段长度**。
  static FieldMatch _classify(
    List<int> steps,
    int start,
    int end,
    int docLength,
  ) {
    bool char = false;
    bool syl = false;
    bool ini = false;
    for (final int s in steps) {
      if (s == 0) {
        char = true;
      } else if (s == 1 || s == 2) {
        syl = true;
      } else {
        ini = true;
      }
    }
    final MatchStrength strength;
    if (!syl && !ini) {
      strength = MatchStrength.original;
    } else if (!char && !syl) {
      strength = MatchStrength.initials;
    } else {
      // 混合输入（「周jl」「jay周杰伦」）按拼音处理：
      // 它确实用到了拼音信息，但不该冒充"完全手打命中"。
      strength = MatchStrength.pinyin;
    }
    final MatchPosition position;
    if (start == 0 && end == docLength) {
      position = MatchPosition.exact;
    } else if (start == 0) {
      position = MatchPosition.prefix;
    } else {
      position = MatchPosition.contains;
    }
    return FieldMatch(
      strength: strength,
      position: position,
      start: start,
      end: end,
    );
  }

  static bool _better(FieldMatch a, FieldMatch b) {
    final int sa = _strengthBase(a.strength) + _positionBase(a.position);
    final int sb = _strengthBase(b.strength) + _positionBase(b.position);
    if (sa != sb) return sa > sb;
    if (a.start != b.start) return a.start < b.start;
    return a.end > b.end;
  }
}
