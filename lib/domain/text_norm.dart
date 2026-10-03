/// 文本归一化 —— **只用于索引键与查询键**，永不改写展示用原文。
///
/// ## 为什么必须"只用于键"
///
/// 需求（拼音模糊搜索 §3 / §4）明确要求：
/// - 归一化可以处理大小写、全角半角、标点与空格；
/// - 但**不得删除或改写原始字段中的版本词**
///   （Live / Remastered / 现场 / 伴奏 …）。
///
/// 所以这里的原则是：`Track.title` / `artists` / `album.name` **一个字节都不动**，
/// 展示与管理页面永远显示服务端原文；归一化只发生在
/// `SearchDoc` 的键里，以及用户输入的查询串上。
///
/// ## 归一化规则（有顺序）
/// 1. **全角 → 半角**（`！` → `!`、`Ａ` → `A`、全角空格 → 半角空格）；
/// 2. **大小写折叠**：拉丁字母统一小写；
/// 3. **`ü/u:` → `v`**：拼音库里 `ü` 一律写作 `v`（`女` → `nv`），
///    查询串必须跟随，否则「女」永远搜不到；
/// 4. **丢弃空白与标点/符号**：`-` `_` `.` `·` `（` `"` `♪` … 全部丢掉，
///    因此「七里香」与「七里香 (Live版)」都能被 `qlx` 命中；
/// 5. **保留**：汉字、假名、谚文、字母、数字（含带音标的拉丁字母）。
///
/// ## 版本词为什么不会被误删
///
/// 第 4 步只丢**标点/空白**，从不丢字母数字。
/// 所以 `Remastered` / `Live` / `伴奏` 会原样留在归一化键里
/// （`七里香live版`），搜索时既不影响「qlx」命中，也可以按关键词精确找到它们；
/// 同时 [TextNorm.versionTags] 会把识别出的版本词单独留一份，
/// 供将来做「过滤伴奏/现场」这类筛选（需求 §3 的"可保留"要求）。
class TextNorm {
  TextNorm._();

  /// 归一化算法的版本。
  ///
  /// ⚠️ 它参与**搜索索引缓存的失效判定**：规则一变，旧缓存必须整份重算，
  /// 否则会出现「新规则 + 旧键」的混合索引，结果无法解释。
  static const int version = 1;

  /// 版本词表（**只用于"标记"，不用于删除**）。
  ///
  /// 需求 §3：「版本词不删除，索引中可额外保留这些词用于未来筛选，
  /// 但搜索匹配不能把它们误删」。这里就是把它们"标出来"的地方。
  static const List<String> versionWords = <String>[
    'live', 'remaster', 'remastered', 'remastering', 'acoustic', 'unplugged',
    'instrumental', 'karaoke', 'demo', 'mono', 'stereo', 'deluxe', 'edition',
    'version', 'ver', 'mix', 'remix', 'radio', 'edit', 'extended', 'bonus',
    '现场', '现场版', '演唱会', '演唱会版', '伴奏', '纯音乐', '翻唱', '试听',
    '母带', '重制', '重置', '混音', '加长版', '电台版', 'demo版', '不插电',
    '钢琴版', '吉他版', '童声版', '合唱版', '独唱版', '清唱', '清唱版',
  ];

  /// 该字符是否是汉字（含扩展 A 与兼容区）。
  static bool isHan(int rune) =>
      (rune >= 0x3400 && rune <= 0x9FFF) ||
      (rune >= 0xF900 && rune <= 0xFAFF) ||
      (rune >= 0x20000 && rune <= 0x2FA1F);

  /// 全角 → 半角（含全角空格）。
  static String toHalfWidth(String input) {
    final StringBuffer sb = StringBuffer();
    for (final int r in input.runes) {
      if (r == 0x3000) {
        sb.write(' ');
      } else if (r >= 0xFF01 && r <= 0xFF5E) {
        sb.writeCharCode(r - 0xFEE0);
      } else {
        sb.writeCharCode(r);
      }
    }
    return sb.toString();
  }

  /// 归一化成**索引键 / 查询键**（不含空格与标点）。
  static String key(String input) {
    if (input.isEmpty) return '';
    final StringBuffer sb = StringBuffer();
    for (final int r in toHalfWidth(input).runes) {
      if (!_keep(r)) continue;
      // 大小写折叠 + 拼音化的 `ü`（`女` → `nv`，两者必须一致）
      if (r == 0xFC || r == 0xDC) {
        sb.write('v');
      } else if (r >= 0x41 && r <= 0x5A) {
        sb.writeCharCode(r + 0x20);
      } else {
        sb.writeCharCode(r);
      }
    }
    // `u:` 与 `v` 等价（用户可能按键盘习惯输入 nu:）
    return sb.toString().replaceAll('u:', 'v');
  }

  /// 把查询串切成**多个关键词**（按空白切分），每段各自归一化。
  ///
  /// 需求 §3：「多个关键词之间默认 AND 关系」。
  /// 按空白切分是因为中文输入法里「周杰伦 晴天」这种两段式查询非常常见；
  /// 不切分会退化成"整串必须连续出现"，几乎搜不到东西。
  static List<String> tokens(String input) {
    final List<String> out = <String>[];
    for (final String part in toHalfWidth(input).split(RegExp(r'\s+'))) {
      final String k = key(part);
      if (k.isNotEmpty) out.add(k);
    }
    return out;
  }

  /// 取出文本里出现的版本词（去重，保持出现顺序）。
  ///
  /// **不参与打分**，只随索引一起落盘，供将来的「过滤现场/伴奏」用。
  static List<String> versionTags(String input) {
    final String k = key(input);
    if (k.isEmpty) return const <String>[];
    final List<String> out = <String>[];
    for (final String w in versionWords) {
      if (k.contains(w) && !out.contains(w)) out.add(w);
    }
    return out;
  }

  /// 是否是"可用于匹配"的字符。
  ///
  /// 用**黑名单**（丢标点/符号/空白）而不是白名单，
  /// 这样日文假名、韩文、西里尔字母、带音标的拉丁字母都能保留下来
  /// —— 曲库里出现这些字符非常正常，白名单会把它们悄悄吃掉。
  static bool _keep(int r) {
    // ASCII：只留 0-9 A-Z a-z
    if (r < 0x80) {
      return (r >= 0x30 && r <= 0x39) ||
          (r >= 0x41 && r <= 0x5A) ||
          (r >= 0x61 && r <= 0x7A);
    }
    // Latin-1 补充 / 标点：© ® ° ± 以及中点 ·（歌手分隔符）
    if (r >= 0xA0 && r <= 0xBF) return false;
    // 通用标点、上下标、货币、字母式符号、箭头、数学与技术符号、制表符、几何、杂项符号、装饰符
    if (r >= 0x2000 && r <= 0x2BFF) return false;
    // CJK 标点（、。「」『』〜…）与康熙部首以外的兼容标点
    if (r >= 0x3000 && r <= 0x303F) return false;
    if (r >= 0xFE30 && r <= 0xFE4F) return false;
    // 全角形式（此时剩下的都是全角符号，因为全角字母数字已转半角）
    if (r >= 0xFF00 && r <= 0xFFEF) return false;
    // 表情、装饰符号、私用区
    if (r >= 0x1F000) return false;
    if (r >= 0xE000 && r <= 0xF8FF) return false;
    return true;
  }
}
