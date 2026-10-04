import 'package:dio/dio.dart';

import '../core/log.dart';
import '../domain/json_util.dart';
import '../domain/lyric.dart';

/// 一次在线歌词查询的输入（全部来自曲库元数据）。
class OnlineLyricQuery {
  final String title;
  final String artist;
  final String album;

  /// 时长。用于**核对候选**：同名不同版本的曲子时长往往不同，
  /// 这是区分「原版 / Live / Remix」最可靠的信号之一。
  final Duration? duration;

  const OnlineLyricQuery({
    required this.title,
    this.artist = '',
    this.album = '',
    this.duration,
  });
}

/// 一条在线歌词候选。
class OnlineLyricCandidate {
  final String title;
  final String artist;
  final String album;
  final Duration? duration;

  /// 带时间轴的歌词（LRC）。
  final String? syncedLyrics;

  /// 纯文本歌词（无时间轴）。
  final String? plainLyrics;

  /// 与查询的匹配置信度（0~1），由 [OnlineLyricMatcher] 算出。
  final double score;

  /// 来源名（展示给用户，例如 `LRCLIB`）。
  final String source;

  const OnlineLyricCandidate({
    required this.title,
    required this.artist,
    required this.album,
    required this.score,
    required this.source,
    this.duration,
    this.syncedLyrics,
    this.plainLyrics,
  });

  /// 是否真的有歌词内容（有些条目只有元数据）。
  bool get hasContent => content.isNotEmpty;

  /// 取该条目**实际可用**的歌词文本。
  ///
  /// ⚠️ 判据是「解析后有效」，不是「非空」（评审意见 D5）：
  /// 有些条目 `syncedLyrics` 非空但内容只有 `♪` 或时间标签，
  /// 而 `plainLyrics` 是有正文的 —— 只看非空会把有效正文丢掉，
  /// 于是"明明有纯文本歌词却什么都看不到"。
  /// 顺序仍是「先同步歌词，后纯文本」，只是每一步都要求有效。
  String get content {
    final String synced = syncedLyrics ?? '';
    if (synced.trim().isNotEmpty && isUsableLyricText(synced)) return synced;
    final String plain = plainLyrics ?? '';
    if (plain.trim().isNotEmpty && isUsableLyricText(plain)) return plain;
    return '';
  }

  /// 一段歌词文本「解析后」是否达到 [LyricDoc.usableCharThreshold]。
  static bool isUsableLyricText(String raw) {
    final List<LyricLine> lines = LyricDoc.parseLrc(raw);
    if (lines.isEmpty) {
      // 不是 LRC：把整段当纯文本评估
      return LyricDoc.informativeCharCount(raw) >= LyricDoc.usableCharThreshold;
    }
    int total = 0;
    for (final LyricLine l in lines) {
      total += LyricDoc.informativeCharCount(l.text);
      if (total >= LyricDoc.usableCharThreshold) return true;
    }
    return false;
  }

  OnlineLyricCandidate withScore(double value) => OnlineLyricCandidate(
        title: title,
        artist: artist,
        album: album,
        duration: duration,
        syncedLyrics: syncedLyrics,
        plainLyrics: plainLyrics,
        score: value,
        source: source,
      );
}

/// 在线歌词来源（可替换 —— 测试里注入假实现即可，不需要任何网络）。
///
/// ## 契约（实现方只需做到这些）
/// `search` 负责**按元数据把候选捞回来**：
/// - 只返回**真有歌词内容**的条目（见 [OnlineLyricCandidate.hasContent]），
///   只有元数据的丢掉；
/// - 顺序按相关度从高到低（用户在候选列表里看到的就是这个顺序）。
///
/// ⚠️ **可以不填 `score`**。阈值判定是 `LyricRepository` 的策略，
/// 它会用 [OnlineLyricMatcher] 对每条候选**重新打分**再决定要不要自动绑定 ——
/// 策略只应存在于一处，来源实现不该影响「多少分算匹配」。
abstract class OnlineLyricSource {
  /// 展示给用户的来源名。
  String get displayName;

  /// 按元数据搜索候选。**实现必须自己保证不抛异常**，
  /// 或至少让调用方容易 catch —— 在线服务绝不能影响播放。
  Future<List<OnlineLyricCandidate>> search(OnlineLyricQuery query);
}

/// 匹配打分器（**纯函数**，便于单测）。
///
/// ## 为什么要严格打分
/// 需求明确：「标题和歌手不匹配或匹配置信度不足时，不要自动绑定错误歌词」。
/// 把错歌词绑上去比没有歌词更糟 —— 用户会以为播放器坏了。
///
/// ## 打分规则
/// | 维度 | 情况 | 加分 |
/// |---|---|---|
/// | 标题 | 归一化后完全相同 | +0.55 |
/// | 标题 | 互相包含 | +0.35 |
/// | 标题 | 无关 | **直接判 0（不匹配）** |
/// | 歌手 | 相同 | +0.30 |
/// | 歌手 | 互相包含 | +0.18 |
/// | 歌手 | 都不同 | −0.15 |
/// | 歌手 | 有一方缺失 | +0.15（中性偏正） |
/// | 时长 | 差 ≤3 秒 | +0.20 |
/// | 时长 | 差 ≤10 秒 | +0.10 |
/// | 时长 | 差 >30 秒 | −0.20 |
class OnlineLyricMatcher {
  const OnlineLyricMatcher._();

  /// 自动绑定的门槛。低于它只作为「候选」交给用户手动选。
  static const double acceptThreshold = 0.7;

  /// 归一化：小写、去括号内容、去版本后缀词、去所有非字母数字汉字。
  ///
  /// 括号内容（`(Remastered)` / `[Live]`）与 `feat.` 这类差异
  /// 是「同一首歌」最常见的写法分歧，不归一化会白白漏掉正确结果。
  static String normalize(String raw) {
    var t = raw.toLowerCase();
    t = t.replaceAll(RegExp(r'[\(\[（【].*?[\)\]）】]'), ' ');
    t = t.replaceAll(
      RegExp(r'\b(remaster(ed)?|live|acoustic|version|feat|ft|with|deluxe)\b'),
      ' ',
    );
    t = t.replaceAll(RegExp(r'[^0-9a-z\u4e00-\u9fa5]+'), '');
    return t;
  }

  /// 歌手名归一化：只取第一个歌手（`A feat. B` → `A`）。
  static String normalizeArtist(String raw) {
    var s = raw.toLowerCase();
    s = s.split(RegExp(r'[,;&/]|feat\.?|ft\.?|、')).first;
    return normalize(s);
  }

  static double score(OnlineLyricQuery q, OnlineLyricCandidate cand) {
    final String qt = normalize(q.title);
    final String ct = normalize(cand.title);
    if (qt.isEmpty || ct.isEmpty) return 0;

    double s;
    if (qt == ct) {
      s = 0.55;
    } else if (ct.contains(qt) || qt.contains(ct)) {
      s = 0.35;
    } else {
      // 标题都不沾边 → 直接判「不匹配」，不再看歌手与时长。
      return 0;
    }

    final String qa = normalizeArtist(q.artist);
    final String ca = normalizeArtist(cand.artist);
    if (qa.isEmpty || ca.isEmpty) {
      s += 0.15;
    } else if (qa == ca) {
      s += 0.30;
    } else if (qa.contains(ca) || ca.contains(qa)) {
      s += 0.18;
    } else {
      s -= 0.15;
    }

    final Duration? qd = q.duration;
    final Duration? cd = cand.duration;
    if (qd != null && cd != null && cd.inSeconds > 0 && qd.inSeconds > 0) {
      final int diff = (qd.inSeconds - cd.inSeconds).abs();
      if (diff <= 3) {
        s += 0.20;
      } else if (diff <= 10) {
        s += 0.10;
      } else if (diff > 30) {
        s -= 0.20;
      }
    }

    return s.clamp(0.0, 1.0);
  }
}

/// LRCLIB 在线歌词源（<https://lrclib.net>）。
///
/// ## 为什么选它
/// - **免费、开放、无需 API Key** —— 需求明确禁止把密钥放进客户端；
///   用免密钥服务从根上避免了这个问题；
/// - 曲库是社区共建的公共领域歌词库，接口简单（`/api/search`），
///   返回同时含 `syncedLyrics`（LRC，带时间轴）与 `plainLyrics`；
/// - 使用条款要求客户端表明身份，因此这里固定带 `User-Agent`。
///
/// ## 现实约束（务必如实告知用户）
/// 它是**境外服务**。电视所在网络不一定能直连 ——
/// 因此它只作为 **NAS 歌词缺失时的兜底**，并且：
/// - 有独立的、更短的超时（默认 8 秒）；
/// - 任何失败都**静默降级**为「暂无歌词」，绝不影响播放；
/// - 可以用 [LyricRepository.onlineEnabled] 整体关掉。
///
/// ⚠️ 本机（开发环境）无法验证电视端网络能否访问该服务，
/// 这一点在交付说明里必须如实标注为「未真机验证」。
class LrclibLyricSource implements OnlineLyricSource {
  LrclibLyricSource({
    Dio? dio,
    this.requestTimeout = const Duration(seconds: 8),
  }) : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 6),
                receiveTimeout: const Duration(seconds: 8),
                headers: defaultHeaders,
              ),
            );

  static const String baseUrl = 'https://lrclib.net/api';

  /// 请求头。
  ///
  /// ⚠️ **每次请求都显式带上**，而不是只塞进自建 Dio 的 `BaseOptions`：
  /// 构造时可以注入外部 Dio（测试、或将来的 HTTP 客户端），
  /// 那种情况下 BaseOptions 不是我们建的那份，`User-Agent` 就丢了 ——
  /// 违反 LRCLIB 使用条款，且真实故障发生在用户机器上。
  static const Map<String, String> defaultHeaders = <String, String>{
    // LRCLIB 使用条款要求客户端标识自己
    'User-Agent':
        'feiniu-tv-music/1.0 (Android TV; +https://github.com/xch1996911-ai/feiniu-tv-music)',
    'Accept': 'application/json',
  };

  final Dio _dio;

  /// 单次搜索的硬上限（外层再包一层，防止 Dio 超时未触发）。
  final Duration requestTimeout;

  @override
  String get displayName => 'LRCLIB';

  @override
  Future<List<OnlineLyricCandidate>> search(OnlineLyricQuery query) async {
    final String title = query.title.trim();
    if (title.isEmpty) return const <OnlineLyricCandidate>[];

    final Response<dynamic> res = await _dio
        .get<dynamic>(
          '$baseUrl/search',
          queryParameters: <String, dynamic>{
            'track_name': title,
            if (query.artist.trim().isNotEmpty) 'artist_name': query.artist.trim(),
          },
          // 显式带请求头：注入的 Dio 可能没有我们的 BaseOptions
          options: Options(headers: defaultHeaders),
        )
        .timeout(requestTimeout);

    final dynamic data = res.data;
    if (data is! List) {
      Log.w('LYRIC_ONLINE 响应不是数组（${data.runtimeType}）');
      return const <OnlineLyricCandidate>[];
    }

    final out = <OnlineLyricCandidate>[];
    for (final dynamic raw in data) {
      if (raw is! Map) continue;
      final Map<String, dynamic> m = Map<String, dynamic>.from(raw);

      final int? seconds = jsonIntOrNull(m['duration']);
      final OnlineLyricCandidate cand = OnlineLyricCandidate(
        title: jsonString(m['trackName']),
        artist: jsonString(m['artistName']),
        album: jsonString(m['albumName']),
        duration: seconds == null || seconds <= 0
            ? null
            : Duration(seconds: seconds),
        syncedLyrics: jsonStringOrNull(m['syncedLyrics']),
        plainLyrics: jsonStringOrNull(m['plainLyrics']),
        score: 0,
        source: displayName,
      );
      if (!cand.hasContent) continue; // 只有元数据、没有歌词的条目直接丢
      out.add(cand.withScore(OnlineLyricMatcher.score(query, cand)));
    }

    out.sort((OnlineLyricCandidate a, OnlineLyricCandidate b) =>
        b.score.compareTo(a.score));
    return out;
  }
}
