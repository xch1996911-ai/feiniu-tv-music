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
    final String stripped = raw.replaceAll(_timeTag, ' ');
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

    final text = jsonStringOrNull(entry['text']);
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

    // 非 LRC 文本（纯文本歌词）：**按换行拆成多行**，`time` 全部为 null
    // —— 它没有逐句时间轴，显示与浏览都正常，只是不参与高亮/滚动
    //（UI 会显示「纯文本歌词 · 不支持逐句同步」）。
    //
    // ⚠️ 旧实现把整段文本塞成**一行**：
    //    · 多段歌词只显示第一行（或挤成一行）
    //    · `time` 取的是「这个歌词源的开始时间」，一旦为 null，
    //      `activeLineIndex()` 永远返回 -1 ⇒ 高亮与滚动都不动
    //      （实机「歌曲有歌词但不跟随」的根因）。
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

  /// 解析 LRC 文本为逐行歌词。
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
      if (matches.isEmpty) {
        // 纯元数据标签（`[ar:xxx]` / `[ti:xxx]`）或没有时间轴的裸文本。
        if (line.startsWith('[') && line.endsWith(']')) continue;
        out.add(LyricLine(text: line));
        continue;
      }

      final text = line.substring(matches.last.end).trim();
      for (final m in matches) {
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
        out.add(LyricLine(
          text: text,
          time: Duration(
            milliseconds:
                minutes * 60000 + seconds * 1000 + millis + docOffsetMs,
          ),
        ));
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

  /// 便捷构造：直接解析一段 LRC 或纯文本。
  static LyricDoc parse(String raw) {
    final List<LyricLine> lines = parseLrc(raw);
    if (lines.isNotEmpty) return LyricDoc(lines: lines);
    return LyricDoc(lines: <LyricLine>[LyricLine(text: raw)]);
  }

  /// 文本看起来是不是 LRC（含时间标签）。
  static bool _looksLikeLrc(String text) => _timeTag.hasMatch(text);

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
