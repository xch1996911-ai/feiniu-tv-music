/// 统一风格集合、归纳来源与置信度 —— 风格归纳的**唯一词汇表**。
///
/// ## 为什么先定「集合」再谈「归纳」
///
/// 曲库里的风格标签是自由文本：服务端可能是 `Pop`、`pop music`、`华语流行`，
/// 文件标签可能是 `Alternative Rock`、`独立摇滚`。若直接拿来当分组名，
/// 风格页会出现几十个互相包含的条目（`摇滚` / `摇滚乐` / `Rock` 三个分类），
/// 完全没法用。
///
/// 所以先固定一个**有限**的统一集合（需求给定的 11 类 + 「待分类」），
/// 再把各种来源的标签**规范映射**进去。映射不上的**明确标签**保留原样
/// （见 [GenreRules.mapExplicitTag] 的说明），不丢数据、不硬塞。
library;

/// 归纳来源。**顺序即优先级**（前者永不被后者覆盖）。
enum GenreSource {
  /// 用户手动确认/修改。最高优先级，自动归纳**永不覆盖**。
  manual,

  /// 歌曲文件或服务端给出的明确风格标签。
  serverTag,

  /// 专辑内已被明确标签确认的风格，传播给同专辑其他曲目。
  albumRule,

  /// 标题 / 专辑名里出现的**明确类型词**。
  titleRule,

  /// 同一歌手其他**已确认**曲目的常见风格（较弱辅助）。
  artistRule;

  /// 是否属于「推断」（而非原始标签 / 用户设定）。
  ///
  /// 概览页据此显示「推断」标识 —— 需求明确要求
  /// 「避免把推断当作原始标签」。
  bool get isInferred =>
      this == GenreSource.albumRule ||
      this == GenreSource.titleRule ||
      this == GenreSource.artistRule;

  /// 诊断/概览用的短标签。
  String get label => switch (this) {
        GenreSource.manual => '手动',
        GenreSource.serverTag => '标签',
        GenreSource.albumRule => '专辑推断',
        GenreSource.titleRule => '标题推断',
        GenreSource.artistRule => '歌手推断',
      };

  /// 优先级权重：数字越小越强。
  int get rank => switch (this) {
        GenreSource.manual => 0,
        GenreSource.serverTag => 1,
        GenreSource.albumRule => 2,
        GenreSource.titleRule => 3,
        GenreSource.artistRule => 4,
      };
}

/// 一条风格归属：某首歌属于某个风格，以及依据。
class GenreAssignment {
  final String genre;
  final GenreSource source;
  final double confidence;

  const GenreAssignment({
    required this.genre,
    required this.source,
    required this.confidence,
  });
}

/// 归纳规则常量与标签映射表。
class GenreRules {
  GenreRules._();

  /// **规则版本**。
  ///
  /// ⚠️ 改动下面任何映射表 / 阈值 / 版本词表时**必须 +1**：
  /// 索引里记录了产出结果时的版本号，版本不同即视为需要重算
  /// （见 `CatalogueIndex.genreRuleVersion`）。
  /// 不这么做的话，用户升级 App 后会一直看到旧规则的结果，
  /// 而「为什么这条没生效」是极难排查的。
  static const int version = 1;

  /// 证据不足时的归属。**不是一种风格**，是「还没有结论」。
  static const String unclassified = '待分类';

  /// 统一风格集合（顺序即展示顺序）。
  ///
  /// ⚠️ 语言属性（中文/英文/粤语…）**不在其中**：需求明确要求
  /// 「中文/英文等语言属性单独处理，不能当作音乐风格」。
  static const List<String> unified = <String>[
    '流行',
    '摇滚',
    '民谣',
    '电子',
    '嘻哈/说唱',
    '爵士',
    '古典',
    'R&B/灵魂',
    '金属',
    '乡村',
    '器乐/环境',
  ];

  /// 版本 / 编曲信息词表。
  ///
  /// 需求：「标题里的 Live/现场、Remastered/重制、Acoustic/原声版
  /// 主要是版本或编曲信息，**不能直接断定风格**」。
  ///
  /// 这些词出现在标签或标题里时**一律不参与风格判定** ——
  /// 既不能据此归类，也不能当作「有标签」的证据。
  static const Set<String> versionWords = <String>{
    'live', '现场', '现场版', '演唱会',
    'remaster', 'remastered', '重制', '重制版', '母带重制',
    'acoustic', '原声', '原声版', 'unplugged', '不插电',
    'demo', '小样', '试听', '试听版',
    'karaoke', '伴奏', '伴奏版', 'instrumental version',
    'remix', '混音', '混音版', 'radio edit', '电台版',
    'album version', 'single version', 'deluxe', '豪华版',
    'cover', '翻唱', '翻唱版', 'hd', 'hq', '24bit',
  };

  /// 原始标签 → 统一风格 的映射表。
  ///
  /// key 一律**小写、去空格/连字符/下划线/点**后的形态（见 [normalizeKey]），
  /// 这样 `R&B`、`r & b`、`R and B`（→ 仍需单独列出）、`r&b` 能命中同一项。
  static const Map<String, List<String>> alias = <String, List<String>>{
    // ── 流行 ──────────────────────────────────────────────
    'pop': <String>['流行'],
    '流行': <String>['流行'],
    '流行乐': <String>['流行'],
    'popmusic': <String>['流行'],
    '华语流行': <String>['流行'],
    'mandopop': <String>['流行'],
    'cpop': <String>['流行'],
    'jpop': <String>['流行'],
    'kpop': <String>['流行'],
    'citypop': <String>['流行'],
    'synthpop': <String>['流行', '电子'],
    'electropop': <String>['流行', '电子'],
    'dancepop': <String>['流行', '电子'],
    '抒情': <String>['流行'],
    'ballad': <String>['流行'],
    'teenpop': <String>['流行'],
    'adultcontemporary': <String>['流行'],

    // ── 摇滚 ──────────────────────────────────────────────
    'rock': <String>['摇滚'],
    '摇滚': <String>['摇滚'],
    '摇滚乐': <String>['摇滚'],
    'rockmusic': <String>['摇滚'],
    '华语摇滚': <String>['摇滚'],
    'indierock': <String>['摇滚'],
    '独立摇滚': <String>['摇滚'],
    'altrock': <String>['摇滚'],
    'alternativerock': <String>['摇滚'],
    'alternative': <String>['摇滚'],
    'punk': <String>['摇滚'],
    '朋克': <String>['摇滚'],
    'punkrock': <String>['摇滚'],
    'grunge': <String>['摇滚'],
    'postrock': <String>['摇滚'],
    '后摇': <String>['摇滚'],
    'britpop': <String>['摇滚'],
    'classicrock': <String>['摇滚'],
    '经典摇滚': <String>['摇滚'],
    'hardrock': <String>['摇滚', '金属'],
    'progrock': <String>['摇滚'],
    'progressiverock': <String>['摇滚'],
    '前卫摇滚': <String>['摇滚'],
    'psychedelicrock': <String>['摇滚'],
    '迷幻摇滚': <String>['摇滚'],
    'garagerock': <String>['摇滚'],
    'southernrock': <String>['摇滚'],
    'bluesrock': <String>['摇滚'],
    'folkrock': <String>['摇滚', '民谣'],

    // ── 民谣 ──────────────────────────────────────────────
    'folk': <String>['民谣'],
    '民谣': <String>['民谣'],
    'folkmusic': <String>['民谣'],
    '华语民谣': <String>['民谣'],
    '校园民谣': <String>['民谣'],
    '乡村民谣': <String>['民谣'],
    'singer-songwriter': <String>['民谣'],
    'singersongwriter': <String>['民谣'],
    '唱作': <String>['民谣'],
    '独立民谣': <String>['民谣'],
    'indiefolk': <String>['民谣'],

    // ── 电子 ──────────────────────────────────────────────
    '电子': <String>['电子'],
    '电音': <String>['电子'],
    'electronic': <String>['电子'],
    'electronicmusic': <String>['电子'],
    'edm': <String>['电子'],
    'house': <String>['电子'],
    'deephouse': <String>['电子'],
    'techno': <String>['电子'],
    'trance': <String>['电子'],
    'dubstep': <String>['电子'],
    'drumandbass': <String>['电子'],
    'dnb': <String>['电子'],
    'synthwave': <String>['电子'],
    'vaporwave': <String>['电子'],
    'electro': <String>['电子'],
    'dance': <String>['电子'],
    '电子舞曲': <String>['电子'],
    'electronica': <String>['电子'],
    'idm': <String>['电子'],

    // ── 嘻哈 / 说唱 ───────────────────────────────────────
    'hiphop': <String>['嘻哈/说唱'],
    'hip-hop': <String>['嘻哈/说唱'],
    'rap': <String>['嘻哈/说唱'],
    '说唱': <String>['嘻哈/说唱'],
    '嘻哈': <String>['嘻哈/说唱'],
    '华语说唱': <String>['嘻哈/说唱'],
    'trap': <String>['嘻哈/说唱'],
    'grime': <String>['嘻哈/说唱'],
    'gangstarap': <String>['嘻哈/说唱'],
    'oldschoolhiphop': <String>['嘻哈/说唱'],

    // ── 爵士 ──────────────────────────────────────────────
    'jazz': <String>['爵士'],
    '爵士': <String>['爵士'],
    '爵士乐': <String>['爵士'],
    'smoothjazz': <String>['爵士'],
    'bossa': <String>['爵士'],
    'bossanova': <String>['爵士'],
    'swing': <String>['爵士'],
    'bebop': <String>['爵士'],
    'jazzfusion': <String>['爵士'],
    'bigband': <String>['爵士'],

    // ── 古典 ──────────────────────────────────────────────
    'classical': <String>['古典'],
    '古典': <String>['古典'],
    '古典音乐': <String>['古典'],
    'classicalmusic': <String>['古典'],
    'baroque': <String>['古典'],
    '巴洛克': <String>['古典'],
    'symphony': <String>['古典'],
    '交响乐': <String>['古典'],
    'chambermusic': <String>['古典'],
    '室内乐': <String>['古典'],
    'orchestral': <String>['古典'],
    '管弦乐': <String>['古典'],
    'opera': <String>['古典'],
    '歌剧': <String>['古典'],
    'romantic': <String>['古典'],
    'piano': <String>['古典'],

    // ── R&B / 灵魂 ────────────────────────────────────────
    'r&b': <String>['R&B/灵魂'],
    'rb': <String>['R&B/灵魂'],
    'randb': <String>['R&B/灵魂'],
    'rhythmandblues': <String>['R&B/灵魂'],
    'rnb': <String>['R&B/灵魂'],
    'soul': <String>['R&B/灵魂'],
    '灵魂': <String>['R&B/灵魂'],
    '灵魂乐': <String>['R&B/灵魂'],
    'neosoul': <String>['R&B/灵魂'],
    'funk': <String>['R&B/灵魂'],
    '放克': <String>['R&B/灵魂'],
    'motown': <String>['R&B/灵魂'],
    'contemporaryrnb': <String>['R&B/灵魂'],

    // ── 金属 ──────────────────────────────────────────────
    'metal': <String>['金属'],
    '金属': <String>['金属'],
    '金属乐': <String>['金属'],
    'heavymetal': <String>['金属'],
    '重金属': <String>['金属'],
    'deathmetal': <String>['金属'],
    'blackmetal': <String>['金属'],
    'thrashmetal': <String>['金属'],
    'metalcore': <String>['金属'],
    'powermetal': <String>['金属'],
    'doommetal': <String>['金属'],
    'nu-metal': <String>['金属'],

    // ── 乡村 ──────────────────────────────────────────────
    'country': <String>['乡村'],
    '乡村': <String>['乡村'],
    '乡村音乐': <String>['乡村'],
    'countrymusic': <String>['乡村'],
    'countrypop': <String>['乡村'],
    'bluegrass': <String>['乡村'],
    'americana': <String>['乡村'],
    '乡村摇滚': <String>['乡村'],
    'countryrock': <String>['乡村'],

    // ── 器乐 / 环境 ───────────────────────────────────────
    'instrumental': <String>['器乐/环境'],
    '器乐': <String>['器乐/环境'],
    'ambient': <String>['器乐/环境'],
    '环境音乐': <String>['器乐/环境'],
    '氛围': <String>['器乐/环境'],
    'newage': <String>['器乐/环境'],
    '新世纪': <String>['器乐/环境'],
    'soundtrack': <String>['器乐/环境'],
    'ost': <String>['器乐/环境'],
    '原声带': <String>['器乐/环境'],
    '配乐': <String>['器乐/环境'],
    'drone': <String>['器乐/环境'],
    'postclassical': <String>['器乐/环境', '古典'],
    'lofi': <String>['器乐/环境'],
  };

  /// 把标签规范成映射表的 key：小写、去掉空格 / 连字符 / 下划线 / 中点 / 斜杠。
  ///
  /// ⚠️ `&` **必须保留**（`r&b` 与 `rb` 是两个不同的 key，
  /// 两者都在 [alias] 里显式列出）。
  static String normalizeKey(String raw) => raw
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[\s\-_·./\\]+'), '');

  /// [versionWords] 的规范化形态，供判定使用。
  ///
  /// ⚠️ 必须走这一步：表里既有 `live` 这种单字，也有 `radio edit`
  /// 这种带空格的词条。直接 `contains(原文小写)` 会让
  /// `Radio Edit` 命中而 `radioedit` 不命中，判定结果取决于输入里有没有空格 ——
  /// 这种不确定性在归纳里是不可接受的。
  static final Set<String> _versionWordsNormalized = <String>{
    for (final String w in versionWords) normalizeKey(w),
  };

  /// 判断一个标签是否是**纯粹的版本/编曲词**（不含任何风格信息）。
  static bool isPureVersionWord(String raw) {
    final n = normalizeKey(raw);
    if (n.isEmpty) return false;
    return _versionWordsNormalized.contains(n);
  }

  /// 映射一个**明确标签**（来自服务端或文件）。
  ///
  /// 返回：
  /// - 命中别名表 → 对应的统一风格（可能多个，例如 `Synthpop` → 流行 + 电子）；
  /// - 是纯版本词 → 空列表（**不算风格证据**）；
  /// - 其他 → `[原标签]`，即保留为自定义风格。
  ///
  /// ⚠️ 第三种情况是刻意的：需求要求「规范映射到统一集合」，
  /// 但**丢掉无法映射的明确标签**是更糟的选项 —— 那会让用户明明有标签的
  /// 曲目凭空变成「待分类」。保留原标签既无损、也可解释。
  static List<String> mapExplicitTag(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) return const <String>[];
    if (isPureVersionWord(text)) return const <String>[];
    final List<String>? hit = alias[normalizeKey(text)];
    if (hit != null) return hit;
    // 别名表未命中：尝试「包含」匹配（如 `Alternative Rock` 已显式列出；
    // 更长的组合词由包含判定兜底，取命中的最长 key）。
    final String key = normalizeKey(text);
    String? best;
    for (final String k in alias.keys) {
      if (k.length >= 4 && key.contains(k)) {
        if (best == null || k.length > best.length) best = k;
      }
    }
    if (best != null) return alias[best]!;
    return <String>[text];
  }

  /// 是否包含中日韩统一表意文字（用来区分「按词精确匹配」与「按子串匹配」）。
  static bool _hasCjk(String s) =>
      RegExp(r'[\u3400-\u9fff]').hasMatch(s);

  /// 把自由文本切成「词」。
  ///
  /// - 连续的拉丁字母 / 数字算一个词（`Rock`、`Track01`）；
  /// - 连续的 CJK 字符算一个词（`华语摇滚`）；
  /// - 其余字符（空格、标点、括号、`-`）都是分隔符。
  static List<String> tokenize(String text) {
    final List<String> out = <String>[];
    final StringBuffer buf = StringBuffer();
    bool? cjk;
    void flush() {
      if (buf.isNotEmpty) {
        out.add(buf.toString());
        buf.clear();
      }
    }

    for (final int rune in text.runes) {
      final String ch = String.fromCharCode(rune);
      final bool isWord = RegExp(r'[0-9A-Za-z&]').hasMatch(ch);
      final bool isCjk = RegExp(r'[\u3400-\u9fff]').hasMatch(ch);
      if (!isWord && !isCjk) {
        flush();
        cjk = null;
        continue;
      }
      if (cjk != null && cjk != isCjk) flush();
      cjk = isCjk;
      buf.write(ch);
    }
    flush();
    return out;
  }

  /// 从一段自由文本（标题 / 专辑名）里提取**明确类型词**。
  ///
  /// ## 为什么必须「按词」而不是「按包含」
  /// 直接做子串包含会有大量误判，实测例子：
  /// - `Rocket Man` 含 `rock` → 会被判成摇滚；
  /// - `Ghost` 含 `ost` → 会被判成原声带；
  /// - `Brand New` 含 `rand` → 会被判成 R&B。
  ///
  /// 这些错误一旦发生，用户看到的就是「这首歌为什么跑进这个风格里」，
  /// 而页面上的依据是「标题推断」——**可解释但结论是错的**，比判不出更糟。
  ///
  /// 因此：
  /// - **拉丁词**：与别名 key 做**精确**匹配（`rock` 只匹配 `rock`）；
  /// - **CJK 词**：允许子串命中，但只与「含 CJK 的别名 key」比较，
  ///   且 key 至少 2 个字（`中国摇滚精选` 含 `摇滚` → 命中，符合预期）。
  static List<String> genresFromText(String text) {
    final Set<String> out = <String>{};
    for (final String token in tokenize(text)) {
      final String key = normalizeKey(token);
      if (key.isEmpty) continue;
      if (_versionWordsNormalized.contains(key)) continue;
      final bool cjk = _hasCjk(key);

      if (!cjk) {
        // 拉丁词：精确匹配，且 key 至少 3 个字符（避免 `rb` / `pop` 这类短词误伤）
        if (key.length < 3) continue;
        final List<String>? hit = alias[key];
        if (hit != null) out.addAll(hit);
        continue;
      }

      // CJK 词：与含 CJK 的别名 key 做子串比较
      for (final MapEntry<String, List<String>> e in alias.entries) {
        if (!_hasCjk(e.key)) continue;
        if (e.key.length < 2) continue;
        if (key.contains(e.key)) out.addAll(e.value);
      }
    }
    return out.toList(growable: false);
  }
}
