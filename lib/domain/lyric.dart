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

    final text = jsonStringOrNull(entry['text']);
    if (text != null && _looksLikeLrc(text)) {
      final parsed = parseLrc(text);
      if (parsed.isNotEmpty) {
        return LyricDoc(
          lines: parsed,
          sourceCount: entries.length,
          preferredIndex: index,
        );
      }
    }

    // 非 LRC 文本：按单条歌词处理（time / duration / offset 单位是秒）。
    return LyricDoc(
      lines: <LyricLine>[
        LyricLine(
          text: text ?? '',
          time: _secondsToDuration(entry['time']),
          duration: _secondsToDuration(entry['duration']),
          offset: _secondsToDuration(entry['offset']),
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

    out.sort((a, b) =>
        (a.time ?? Duration.zero).compareTo(b.time ?? Duration.zero));
    return out;
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
