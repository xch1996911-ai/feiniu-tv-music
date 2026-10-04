import 'json_util.dart';

/// 单行歌词。
class LyricLine {
  /// 该行文本（可能为空 —— LRC 里 `[00:03.00]` 这种空行表示停顿）。
  final String text;

  /// 行起始时间。服务端以**秒**下发 `time`，这里统一转成 [Duration]。
  final Duration? time;

  /// 行持续时长（服务端 `duration`，秒）。
  final Duration? duration;

  /// 行偏移（服务端 `offset`，秒）。
  final Duration? offset;

  const LyricLine({
    required this.text,
    this.time,
    this.duration,
    this.offset,
  });

  @override
  String toString() =>
      'LyricLine(${time ?? '-'}) $text';
}

/// 歌词文档。
///
/// 接口：`GET /lyric/list?trackGUID=<track_guid>`
/// ⚠️ 参数名是 **`trackGUID`**（大写 GUID）；写成 `guid` 会得到 `100002 InvalidArgs`。
///
/// 响应结构（真实契约 §7）：`{ list: [...], preferred: <引用> }`
/// - `list` —— 多个歌词源；
/// - `preferred` —— 当前生效的歌词源引用；
/// - 单条歌词源含 `text` / `time`（秒） / `duration` / `offset`。
///
/// V1 只做**逐行歌词**：`text` 若为 LRC 文本则解析出逐行时间轴，
/// 否则退化为单行。逐字歌词（karaoke）不在 Phase 1 范围。
///
/// ⚠️ 说明：真实 NAS 验证阶段未取到歌词样本，`list` 内元素的字段细节
/// （`text` 是否承载整段 LRC）属于**按契约实现的推断**；
/// 本解析器对两种形态都兼容，待真机拿到样本后可进一步收敛。
class LyricDoc {
  final List<LyricLine> lines;

  /// `list` 中的歌词源数量。
  final int sourceCount;

  /// 命中的 `preferred` 下标；无歌词源时为 -1。
  final int preferredIndex;

  const LyricDoc({
    required this.lines,
    this.sourceCount = 0,
    this.preferredIndex = -1,
  });

  static const LyricDoc empty =
      LyricDoc(lines: <LyricLine>[], sourceCount: 0, preferredIndex: -1);

  bool get isEmpty => lines.isEmpty;
  bool get isNotEmpty => lines.isNotEmpty;

  /// 是否**真的有可逐句同步的时间轴**。
  ///
  /// ⚠️ 「有歌词」与「能同步」是两回事：NAS 的歌词源可能是**纯文本**
  /// （没有 `[mm:ss]` 标签），解析出来每一行的 `time` 都是 `null` ——
  /// 这种文档能正常显示与浏览，但 `activeLineIndex()` 永远返回 -1，
  /// 于是高亮与滚动都不会动（实机「歌词不跟随」的根因之一）。
  bool get isSyncable => lines.any((LyricLine l) => l.time != null);

  /// 判定「一段歌词文本是否真的有内容」。
  ///
  /// ## 为什么必须有这个判定（V5 图5 的根因之一）
  ///
  /// 实机现象：播放页歌词区**只有一个音乐符号 `♪`**。
  /// 链路是：NAS 的 `lyric/list` 返回了「非空」的 list，里面那条
  /// `text` 只是占位符或空白 —— 于是 `nasDoc.isNotEmpty` 成立、
  /// **提前 return，在线兜底根本没跑**，界面上就只剩下一个符号。
  ///
  /// 「非空」不等于「有效」：`♪`、`♫`、`·`、`---`、`[00:00.00]`
  /// 这类内容没有任何歌词信息。
  ///
  /// ## 判定规则（刻意保守且可解释）
  /// 去掉时间标签后，只统计**有信息量的字符**：
  /// CJK 汉字 / 拉丁字母 / 数字。其余（符号、标点、空白）一律不算。
  /// 全部行加起来 **≥ 2 个**才算有效。
  ///
  /// - `♪♪♪` → 0 → 无效 ✅
  /// - `[00:12.00]` → 0 → 无效 ✅
  /// - `   ` / `---` / `……` → 0 → 无效 ✅
  /// - `纯音乐，请欣赏` → 6 → 有效 ✅（这确实是服务端给的告知）
  /// - `Oh` / `嗯` → 2 → 有效（宁可放过去，也不要把合法短句误判成无歌词）
  ///
  /// ⚠️ 阈值刻意取 **2** 而不是更大：占位符的信息字符数是 **0**，
  /// 阈值 2 已经足够把它挡掉；再往大调就会开始误伤「真的只有一两个字」的
  /// 合法歌词（例如某些纯音乐提示），那种误判会让在线兜底去绑一份不相关的歌词，
  /// **比少一次兜底更糟**。
  static int informativeCharCount(String raw) {
    if (raw.isEmpty) return 0;
    // ⚠️ **两类**时间标签都要先剥离，否则标签里的数字会被算成「歌词内容」：
    //    方括号 `[00:09.71]` 与增强型 LRC 的行内尖括号 `<00:09.71>`。
    //    实测后果：`<00:09.71><00:10.01>` 这类「只剩标签」的内容会被判为
    //    「有歌词」，从而**阻断在线兜底**（界面上就是一串标签而找不到词）。
    final String stripped =
        raw.replaceAll(_timeTag, ' ').replaceAll(_inlineTimeTag, ' ');
    int n = 0;
    for (final int rune in stripped.runes) {
      final String ch = String.fromCharCode(rune);
      if (RegExp(r'[0-9A-Za-z]').hasMatch(ch)) {
        n++;
      } else if (rune >= 0x3400 && rune <= 0x9fff) {
        n++;
      }
    }
    return n;
  }

  /// 本文档是否**真的有歌词内容**。
  bool get isUsable {
    int total = 0;
    for (final LyricLine l in lines) {
      total += informativeCharCount(l.text);
      if (total >= usableCharThreshold) return true;
    }
    return false;
  }

  /// 有效歌词的最小信息字符数。
  static const int usableCharThreshold = 2;

  /// 时间标签，形如 `[00:12.34]` / `[0:12]` / `[00:12:345]`。
  static final RegExp _timeTag =
      RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

  /// **增强型 LRC（逐字/卡拉 OK）** 的行内时间标签：`<00:12.34>` / `<0:12>`。
  ///
  /// 真实故障（用户截图为证）：歌词区把 `<00:09.71>` `<00:10.01>` 原样显示出来，
  /// 句子被拆碎。原因就是旧解析器只认方括号，把行内尖括号标签当成了歌词正文。
  static final RegExp _inlineTimeTag =
      RegExp(r'<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>');

  /// 文档级偏移标签 `[offset:+500]`（毫秒）。
  static final RegExp _offsetTag =
      RegExp(r'^\[offset:\s*([+-]?\d+)\s*\]$', caseSensitive: false);

  factory LyricDoc.fromJson(Map<String, dynamic> json) {
    final rawList = json['list'];
    final entries = rawList is List
        ? rawList
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
        : <Map<String, dynamic>>[];
    if (entries.isEmpty) return empty;

    final index = _preferredIndex(json['preferred'], entries);
    final entry = entries[index];
    // 源级偏移（秒）：官方前端同样会把 `metadata.offset` 与源级 offset 叠加
    // 进播放时间轴。不叠的话整份歌词会整体偏移（快/慢几秒）。
    final Duration sourceOffset =
        _secondsToDuration(entry['offset']) ?? Duration.zero;

    // ⚠️ 歌词正文的字段名是**按推断的契约**写的（`LyricDoc` 类注释：
    //    真实 NAS 歌词样本从未取到过）。这里对常见命名做兜底兼容 ——
    //    症状链「V5 只有 ♪ → 现在什么都没有」与「字段名猜错 → 解析出
    //    空文本行」完全吻合：V4 的 `isNotEmpty` 把空文本行当成有歌词
    //    （界面上就是一个 ♪），现在的 `isUsable` 把它判为无效后，
    //    在线兜底若也不可达就只剩「暂无歌词」。
    //    真实字段名以诊断页的「歌词原始响应」为准，拿到样本后收敛。
    final text = jsonStringOrNull(entry['text']) ??
        jsonStringOrNull(entry['lyric']) ??
        jsonStringOrNull(entry['lrc']) ??
        jsonStringOrNull(entry['content']) ??
        jsonStringOrNull(entry['lyrics']);
    if (text != null && _looksLikeLrc(text)) {
      final parsed = parseLrc(text);
      if (parsed.isNotEmpty) {
        return LyricDoc(
          // LRC 文本自身的 `[offset:+ms]` 已在 parseLrc 里叠加过；
          // 源级 offset（秒）在这里统一补上。
          lines: sourceOffset == Duration.zero
              ? parsed
              : parsed
                  .map((LyricLine l) => l.time == null
                      ? l
                      : LyricLine(
                          text: l.text,
                          time: l.time! + sourceOffset,
                          duration: l.duration,
                          offset: l.offset,
                        ))
                  .toList(),
          sourceCount: entries.length,
          preferredIndex: index,
        );
      }
    }

    // 非 LRC 文本：分两种情况（与 fnOS 真实契约一致）——
    //
    // ① **源带 `time`**（该歌词源是一个整体块，从 time 秒开始生效）：
    //    保持**单行**并携带契约字段（time/duration/offset，单位秒）。
    //    这是 `fnos_lyric_test` 钉住的契约形态。
    //
    // ② **源没有 `time`**（NAS 常见的占位/纯文本源）：**按换行拆成多行**，
    //    `time` 全部为 null —— 没有逐句时间轴，显示与浏览都正常，
    //    只是不参与高亮/滚动（UI 显示「纯文本歌词 · 不支持逐句同步」）。
    //
    // ⚠️ 最初的实现把两种情况都塞成**一行**且 `time` 直接取源字段：
    //    无时间源时 `time == null` ⇒ `activeLineIndex()` 恒 -1
    //    ⇒ 高亮与滚动都不动（实机「歌曲有歌词但不跟随」的根因）；
    //    多段歌词还被挤成一行。
    final Duration? entryTime = _secondsToDuration(entry['time']);
    if (entryTime != null) {
      return LyricDoc(
        lines: <LyricLine>[
          LyricLine(
            text: text ?? '',
            time: entryTime,
            duration: _secondsToDuration(entry['duration']),
            offset: sourceOffset == Duration.zero
                ? _secondsToDuration(entry['offset'])
                : sourceOffset,
          ),
        ],
        sourceCount: entries.length,
        preferredIndex: index,
      );
    }
    final List<LyricLine> plainLines = (text ?? '')
        .split(RegExp(r'\r\n|\r|\n'))
        .map((String l) => l.trim())
        .where((String l) => l.isNotEmpty)
        .map((String l) => LyricLine(
              text: l,
              time: null,
              duration: _secondsToDuration(entry['duration']),
              offset: sourceOffset == Duration.zero ? null : sourceOffset,
            ))
        .toList();
    if (plainLines.isNotEmpty) {
      return LyricDoc(
        lines: plainLines,
        sourceCount: entries.length,
        preferredIndex: index,
      );
    }

    // 兜底：连文本都没有（理论到不了这里，isUsable 已在仓库层过滤）
    return LyricDoc(
      lines: <LyricLine>[
        LyricLine(
          text: text ?? '',
          time: _secondsToDuration(entry['time']),
          duration: _secondsToDuration(entry['duration']),
          offset: sourceOffset == Duration.zero ? null : sourceOffset,
        ),
      ],
      sourceCount: entries.length,
      preferredIndex: index,
    );
  }

  /// 解析 LRC / 增强型 LRC / 纯文本为逐行歌词。
  ///
  /// ## 支持的四种形态（都要保证「正文干净、能同步」）
  ///
  /// | 输入 | 行起始时间 | 正文 |
  /// |---|---|---|
  /// | `[00:09.71]示例歌词` | 9.71s（方括号） | `示例歌词` |
  /// | `[00:09.71] 示 <00:09.95> 例` | 9.71s（方括号优先） | `示例`（标签剥离 + 中文间空格清理） |
  /// | `<00:09.71>示例歌词` | 9.71s（**取首个尖括号**） | `示例歌词` |
  /// | 无任何标签的纯文本 | null（不参与高亮滚动） | 原文本 |
  ///
  /// ⚠️ **不允许**把标签留在正文里显示（用户截图里的 `<00:09.71>` 就是这么来的）；
  /// 也不允许把一句话按每个字拆成多行 —— 逐字标签只用来**推导行时间**，
  /// 本轮不实现逐字高亮（那需要独立的逐字时间片段模型）。
  static List<LyricLine> parseLrc(String raw) {
    final out = <LyricLine>[];
    var docOffsetMs = 0;

    for (final rawLine in raw.split(RegExp(r'\r\n|\r|\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      final offsetMatch = _offsetTag.firstMatch(line);
      if (offsetMatch != null) {
        docOffsetMs = int.tryParse(offsetMatch.group(1)!) ?? 0;
        continue;
      }

      final matches = _timeTag.allMatches(line).toList();
      final inline = _inlineTimeTag.allMatches(line).toList();

      if (matches.isEmpty && inline.isEmpty) {
        // 纯元数据标签（`[ar:xxx]` / `[ti:xxx]`）或无时间轴的裸文本。
        if (line.startsWith('[') && line.endsWith(']')) continue;
        out.add(LyricLine(text: _cleanText(line)));
        continue;
      }

      // 正文 = 去掉所有时间标签后的剩余文本。
      // 有方括号行标签时以**最后一个**方括号为界（同一行多标签 = 多个时间点）；
      // 行内尖括号标签由 `_cleanText` 处理（它会区分「标签带来的空格」与正文空格）。
      String body = line;
      if (matches.isNotEmpty) {
        body = body.substring(matches.last.end);
      }
      body = _cleanText(body);

      if (matches.isEmpty) {
        // 只有逐字标签：**取该行第一个尖括号时间作为行起始时间**，
        // 这样即使没有方括号，逐行高亮与滚动仍然可用（旧实现 time=null → 不动）。
        out.add(LyricLine(
          text: body,
          time: _timeOf(inline.first, docOffsetMs),
        ));
        continue;
      }

      for (final m in matches) {
        out.add(LyricLine(text: body, time: _timeOf(m, docOffsetMs)));
      }
    }

    // ⚠️ 必须用「下标打破平局」的稳定排序：`List.sort` 不是稳定排序，
    //    而「同一时刻多句」和「纯文本（全部 time == null）」都依赖
    //    **保持输入顺序** —— 否则纯文本歌词会被打乱、同刻两句会被调换。
    final List<int> order = List<int>.generate(out.length, (int i) => i);
    order.sort((int a, int b) {
      final Duration ta = out[a].time ?? Duration.zero;
      final Duration tb = out[b].time ?? Duration.zero;
      if (ta != tb) return ta.compareTo(tb);
      return a.compareTo(b);
    });
    return <LyricLine>[for (final int i in order) out[i]];
  }

  /// 从一个时间标签匹配里取出 [Duration]（含文档级 offset）。
  ///
  /// 分组语义与 [_timeTag] / [_inlineTimeTag] 共用：1=分、2=秒、3=小数。
  static Duration _timeOf(RegExpMatch m, int docOffsetMs) {
    final minutes = int.tryParse(m.group(1)!) ?? 0;
    final seconds = int.tryParse(m.group(2)!) ?? 0;
    final frac = m.group(3);
    var millis = 0;
    if (frac != null && frac.isNotEmpty) {
      millis = frac.length == 1
          ? int.parse(frac) * 100
          : frac.length == 2
              ? int.parse(frac) * 10
              : int.parse(frac.padRight(3, '0').substring(0, 3));
    }
    return Duration(
      milliseconds: minutes * 60000 + seconds * 1000 + millis + docOffsetMs,
    );
  }

  /// 正文清理：剥离行内时间标签，**只删掉「标签带来的」空格**，保留真正的正文空格。
  ///
  /// ## 为什么不能简单地「删掉所有中文之间的空格」
  /// 增强型 LRC 剥离 `<00:09.95>` 后会在片段之间留下空格
  /// （`示 <00:09.95> 例` → 若不处理会显示成「示 例 歌 词」，句子像被拆碎）。
  /// 但「中文之间本来就有空格」的歌词是合法写法，一刀切会**误删正文**。
  ///
  /// ## 采用的规则（可解释、可测）
  /// 1. 先把每个行内标签替换成一个**哨兵字符** —— 于是「标签带来的空格」
  ///    与「正文里本来就有的空格」在数据上被区分开；
  /// 2. 合并连续空白（哨兵不参与合并），去掉首尾空白；
  /// 3. 对每个哨兵：
  ///    - 两侧（跳过空白后）都是 CJK 字符 → 删除哨兵**连同紧邻空白**（这些空白是标签造成的）；
  ///    - 否则 → 退化成**一个普通空格**（英文词间、拉丁文与中文之间需要它）；
  /// 4. 收尾再合并一次连续空格。
  ///
  /// 于是：`示 <..> 例` → `示例`；`Hello <..> world` → `Hello world`；
  /// `第一段 文字`（正文里就有空格、没有标签）→ 原样保留。
  static String _cleanText(String raw) {
    if (raw.isEmpty) return '';

    // ① 行内标签 → 哨兵
    final StringBuffer buf = StringBuffer();
    int last = 0;
    for (final RegExpMatch m in _inlineTimeTag.allMatches(raw)) {
      buf.write(raw.substring(last, m.start));
      buf.writeCharCode(_tagMark);
      last = m.end;
    }
    buf.write(raw.substring(last));

    // ② 合并连续空白（哨兵不参与），并去掉首尾空白
    final List<int> chars = <int>[];
    for (final int r in buf.toString().runes) {
      if (r == 0x20 || r == 0x09 || r == 0x3000 || r == 0x00A0) {
        if (chars.isEmpty) continue; // 前导空白直接丢
        if (chars.last == 0x20) continue; // 连续空白只留一个
        chars.add(0x20);
      } else {
        chars.add(r);
      }
    }
    while (chars.isNotEmpty && chars.last == 0x20) {
      chars.removeLast();
    }

    // ③ 哨兵决策
    for (int i = 0; i < chars.length; i++) {
      if (chars[i] != _tagMark) continue;
      int p = i - 1;
      while (p >= 0 && (chars[p] == 0x20 || chars[p] == _tagMark)) {
        p--;
      }
      int n = i + 1;
      while (n < chars.length && (chars[n] == 0x20 || chars[n] == _tagMark)) {
        n++;
      }
      final bool cjkBoth =
          p >= 0 && n < chars.length && _isCjkLike(chars[p]) && _isCjkLike(chars[n]);
      if (cjkBoth) {
        chars[i] = _dropMark;
        for (int k = i - 1; k >= 0 && chars[k] == 0x20; k--) {
          chars[k] = _dropMark;
        }
        for (int k = i + 1; k < chars.length && chars[k] == 0x20; k++) {
          chars[k] = _dropMark;
        }
      } else {
        chars[i] = 0x20;
      }
    }

    // ④ 收尾：丢掉标记、合并可能相邻的空格
    final List<int> finalChars = <int>[];
    for (final int r in chars) {
      if (r == _dropMark) continue;
      if (r == 0x20 && finalChars.isNotEmpty && finalChars.last == 0x20) {
        continue;
      }
      finalChars.add(r);
    }
    while (finalChars.isNotEmpty && finalChars.last == 0x20) {
      finalChars.removeLast();
    }
    return String.fromCharCodes(finalChars);
  }

  /// 行内标签的哨兵字符（Unicode 私用区，歌词正文不可能出现）。
  static const int _tagMark = 0xE000;

  /// 待删除标记。
  static const int _dropMark = 0xE001;

  /// 是否 CJK 系字符（汉字 / 假名 / 谚文 / CJK 标点 / 全角符号）。
  ///
  /// 刻意**不**包含 ASCII 标点与拉丁字母：那些之间的空格是有效内容。
  static bool _isCjkLike(int rune) {
    return (rune >= 0x3000 && rune <= 0x303F) || // CJK 标点
        (rune >= 0x3040 && rune <= 0x30FF) || // 假名
        (rune >= 0x3400 && rune <= 0x4DBF) || // 扩展 A
        (rune >= 0x4E00 && rune <= 0x9FFF) || // 基本区
        (rune >= 0xAC00 && rune <= 0xD7AF) || // 谚文
        (rune >= 0xF900 && rune <= 0xFAFF) || // 兼容汉字
        (rune >= 0xFF00 && rune <= 0xFFEF); // 全角形式
  }

  /// 便捷构造：直接解析一段 LRC 或纯文本。
  static LyricDoc parse(String raw) {
    final List<LyricLine> lines = parseLrc(raw);
    if (lines.isNotEmpty) return LyricDoc(lines: lines);
    return LyricDoc(lines: <LyricLine>[LyricLine(text: raw)]);
  }

  /// 文本看起来是不是 LRC（含**任一种**时间标签）。
  ///
  /// ⚠️ 必须同时认增强型 `<mm:ss.xx>`：只认方括号时，
  /// 「全篇只有尖括号标签」的歌词会被当成纯文本（time 全为 null），
  /// 于是高亮与滚动完全不动 —— 用户看到的是「歌词有，但不跟着唱」。
  static bool _looksLikeLrc(String text) =>
      _timeTag.hasMatch(text) || _inlineTimeTag.hasMatch(text);

  /// 秒（可能带小数）→ [Duration]。
  static Duration? _secondsToDuration(dynamic v) {
    final d = jsonDoubleOrNull(v);
    if (d == null || d < 0) return null;
    return Duration(milliseconds: (d * 1000).round());
  }

  /// 解析 `preferred` 引用：可能是下标、`{text/guid/name}` 对象或标识字符串。
  static int _preferredIndex(dynamic preferred, List<Map<String, dynamic>> entries) {
    final asInt = jsonIntOrNull(preferred);
    if (asInt != null) {
      if (asInt >= 0 && asInt < entries.length) return asInt;
      return 0;
    }
    if (preferred is Map) {
      final guid = jsonStringOrNull(preferred['guid']);
      final name = jsonStringOrNull(preferred['name']);
      final text = jsonStringOrNull(preferred['text']);
      for (var i = 0; i < entries.length; i++) {
        final e = entries[i];
        if (guid != null && e['guid'] == guid) return i;
        if (name != null && e['name'] == name) return i;
        if (text != null && e['text'] == text) return i;
      }
      return 0;
    }
    if (preferred is String) {
      for (var i = 0; i < entries.length; i++) {
        final e = entries[i];
        if (e['guid'] == preferred || e['name'] == preferred) return i;
      }
    }
    return 0;
  }
}
