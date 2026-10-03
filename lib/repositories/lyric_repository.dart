import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/log.dart';
import '../core/result.dart';
import '../domain/lyric.dart';
import '../domain/track.dart';
import '../services/online_lyric_source.dart';
import 'music_repository.dart';

/// 歌词来源（展示给用户，也用于排障）。
enum LyricOrigin {
  /// 没有拿到任何歌词。
  none,

  /// NAS 接口（`GET /lyric/list?trackGUID=`）—— **优先来源**。
  nas,

  /// 在线自动匹配（置信度达标才自动绑定）。
  online,

  /// 用户从候选里**手动选择**的。
  manual;

  /// 展示名。
  String get label => switch (this) {
        LyricOrigin.none => '暂无歌词',
        LyricOrigin.nas => 'NAS 歌词',
        LyricOrigin.online => '在线匹配',
        LyricOrigin.manual => '手动选择',
      };
}

class _CacheEntry {
  final LyricDoc doc;
  final LyricOrigin origin;
  const _CacheEntry(this.doc, this.origin);
}

/// 歌词仓储：只加载**当前歌曲**的歌词，并给出「当前该高亮哪一行」。
///
/// ## 取词顺序（V4）
/// ```
/// 1) NAS 接口  GET /lyric/list?trackGUID=<guid>       ← 优先，有就用
/// 2) 在线匹配  LRCLIB（免密钥）                        ← NAS 没有/失败/空时才走
/// 3) 都没有    → 显示「暂无歌词」，绝不影响播放
/// ```
/// 在线匹配**必须**同时满足「标题匹配」且总分 ≥
/// [OnlineLyricMatcher.acceptThreshold]；否则只把候选**列出来给用户手动选**，
/// 绝不自动绑定 —— 绑错歌词比没有歌词更糟。
///
/// ## 为什么要单独一个仓储
/// 1. 曲库可能有几千首，**绝不能一次加载整个曲库的歌词**；
/// 2. 歌词跟随播放位置需要高频计算，放进 UI 会让 UI 变成数据层；
/// 3. 换歌时必须能取消上一首的加载，避免「上一首的歌词覆盖当前首」。
class LyricRepository extends ChangeNotifier {
  LyricRepository(this._music, {OnlineLyricSource? online}) : _online = online;

  final MusicRepository _music;

  /// 在线兜底来源。为 null 表示**不做在线匹配**（例如测试或用户关闭）。
  final OnlineLyricSource? _online;

  /// 在线匹配总开关。
  ///
  /// 需求要求评估联网能力后再启用；境外服务在部分电视网络下不可达，
  /// 关掉它不影响任何其它功能（只是永远显示「暂无歌词」）。
  static bool onlineEnabled = true;

  /// 当前已加载歌词的曲目 guid；null = 未加载任何歌词。
  String? _loadedGuid;

  LyricDoc _doc = LyricDoc.empty;

  /// 正在加载。
  bool _loading = false;

  /// 加载失败（界面显示「暂无歌词」而不是报错）。
  String? _error;

  /// 当前歌词的来源。
  LyricOrigin _origin = LyricOrigin.none;

  /// 在线候选（自动匹配未达阈值时给用户手动选）。
  List<OnlineLyricCandidate> _candidates = const <OnlineLyricCandidate>[];

  /// 上一次请求的序号：只有最新一次的结果会被采纳。
  int _requestSeq = 0;

  /// NAS 歌词请求的硬上限。
  ///
  /// ⚠️ 必须显式加：Dio 的 `receiveTimeout` 只约束**两个数据包之间的间隔**，
  /// 服务端持续吐字节但永不结束时不会触发。电视上没有 adb，
  /// 「歌词区永远转圈」和「这首没歌词」在屏幕上长得一样，必须靠超时区分。
  ///
  /// 标 `@visibleForTesting` 是为了让这条**安全约束**可被断言 ——
  /// 它一旦被误删，表现是「极少数电视上歌词区永久转圈」，
  /// 属于最难复现的一类故障，必须有测试钉住。
  @visibleForTesting
  static const Duration requestTimeout = Duration(seconds: 12);

  /// 在线匹配的硬上限。比 NAS 更短 —— 它是兜底，不该让用户等太久。
  @visibleForTesting
  static const Duration onlineTimeout = Duration(seconds: 9);

  /// 小缓存：避免来回切歌反复请求同一首（容量很小，按插入顺序淘汰）。
  final Map<String, _CacheEntry> _cache = <String, _CacheEntry>{};
  static const int _cacheSize = 24;

  LyricDoc get doc => _doc;
  bool get isLoading => _loading;
  String? get error => _error;
  String? get loadedGuid => _loadedGuid;
  bool get isEmpty => _doc.isEmpty;
  LyricOrigin get origin => _origin;

  /// 在线候选（可能为空）。
  List<OnlineLyricCandidate> get candidates => _candidates;

  bool get hasCandidates => _candidates.isNotEmpty;

  /// 歌词文档代号：**每次内容被替换都自增**（开始加载新歌 / 加载完成 / 清空 / 失败）。
  ///
  /// 用途：UI 靠它区分「同一份歌词又通知了一次」与「换了一首歌」，
  /// 从而决定要不要把歌词视口弹回顶部 —— 否则切歌后歌词会停在上一首的滚动位置。
  int _docEpoch = 0;
  int get docEpoch => _docEpoch;

  /// 取 [position] 时刻应当高亮的行下标；无歌词返回 -1。
  ///
  /// 语义与 LRC 标准一致：**最后一个 `time <= position` 的行**。
  ///
  /// ## 为什么用线性扫描（不用二分）
  /// 旧实现假定「`time == null` 的行一定连续地排在前面」，二分一踩到 null
  /// 就往前半区收缩。而 `parseLrc` 里无时间轴的行是按 `Duration.zero`
  /// 参与排序的，与真正的 `[00:00.00]` 行先后顺序**不确定**，
  /// 于是二分会漏掉合法行 —— 表现为「高亮跳错句 / 停在第一句不动」。
  int activeLineIndex(Duration position) {
    final lines = _doc.lines;
    if (lines.isEmpty) return -1;
    var ans = -1;
    for (var i = 0; i < lines.length; i++) {
      final t = lines[i].time;
      if (t == null) continue; // 无时间轴的行不参与高亮
      if (t <= position) ans = i;
    }
    return ans;
  }

  /// 加载指定歌曲的歌词。
  ///
  /// [force] 为 true 时忽略缓存（用于「歌词没出来」的手动重试）。
  ///
  /// ## 竞态与残留
  /// 1. 每次调用都会让 [_requestSeq] 自增；请求返回时若自己已不是最新，
  ///    结果**直接丢弃** —— 否则快速切歌会出现「上一首歌词显示在当前首」。
  ///    NAS 与在线两段请求**都**要过这道检查（在线更慢，更容易过期）。
  /// 2. 未命中缓存时**先清空当前歌词再发请求**：否则新歌词回来之前，
  ///    界面上仍然是上一首的歌词。
  Future<void> load(Track track, {bool force = false}) async {
    if (track.guid.isEmpty) return;

    if (!force) {
      final _CacheEntry? cached = _cache[track.guid];
      if (cached != null) {
        Log.i('LYRIC_LOAD 命中缓存 guid=${track.guid} '
            'lines=${cached.doc.lines.length} origin=${cached.origin.name}');
        _apply(track.guid, cached.doc, cached.origin);
        return;
      }
    }

    final seq = ++_requestSeq;
    _loadedGuid = track.guid;
    _doc = LyricDoc.empty;
    _docEpoch++;
    _error = null;
    _origin = LyricOrigin.none;
    _candidates = const <OnlineLyricCandidate>[];
    _loading = true;
    _safeNotify();
    Log.i('LYRIC_LOAD guid=${track.guid}');

    // ── 1) NAS 优先 ──────────────────────────────────────────
    LyricDoc? nasDoc;
    String? nasError;
    try {
      final Result<LyricDoc> res =
          await _music.getLyrics(track.guid).timeout(requestTimeout);
      if (res.isOk) {
        nasDoc = res.value;
      } else {
        nasError = res.error.message;
      }
    } catch (e) {
      nasError = '$e';
      Log.w('LYRIC_ERROR NAS 请求超时或异常 guid=${track.guid} · $e');
    }

    if (seq != _requestSeq) {
      Log.i('LYRIC_LOAD 丢弃过期结果（NAS）guid=${track.guid}');
      return;
    }

    if (nasDoc != null && nasDoc.isNotEmpty) {
      _loading = false;
      _cachePut(track.guid, nasDoc, LyricOrigin.nas);
      _apply(track.guid, nasDoc, LyricOrigin.nas);
      Log.i('LYRIC_LOAD 完成（NAS）guid=${track.guid} '
          'lines=${nasDoc.lines.length}');
      return;
    }

    // ── 2) 在线兜底 ──────────────────────────────────────────
    final OnlineLyricSource? online = _online;
    if (online != null && onlineEnabled) {
      Log.i('LYRIC_LOAD NAS 无歌词${nasError == null ? '' : '（$nasError）'} '
          '→ 尝试在线匹配 guid=${track.guid}');
      try {
        final List<OnlineLyricCandidate> cands = await online
            .search(OnlineLyricQuery(
              title: track.title,
              artist: track.artistNames,
              album: track.album.name,
              duration: track.duration,
            ))
            .timeout(onlineTimeout);

        if (seq != _requestSeq) {
          Log.i('LYRIC_LOAD 丢弃过期结果（在线）guid=${track.guid}');
          return;
        }

        if (cands.isNotEmpty) {
          final OnlineLyricCandidate best = cands.first;
          if (best.score >= OnlineLyricMatcher.acceptThreshold) {
            final LyricDoc doc = _parse(best.content);
            if (doc.isNotEmpty) {
              _loading = false;
              _candidates = List<OnlineLyricCandidate>.unmodifiable(cands);
              _cachePut(track.guid, doc, LyricOrigin.online);
              _apply(track.guid, doc, LyricOrigin.online);
              Log.i('LYRIC_LOAD 完成（在线 ${best.source} '
                  'score=${best.score.toStringAsFixed(2)}）lines=${doc.lines.length}');
              return;
            }
          }
          // 置信度不足 → 只给候选，**不自动绑定**
          _candidates = List<OnlineLyricCandidate>.unmodifiable(cands);
          Log.i('LYRIC_LOAD 在线候选 ${cands.length} 条，'
              '最高分 ${cands.first.score.toStringAsFixed(2)} 未达阈值 '
              '${OnlineLyricMatcher.acceptThreshold} → 交由用户选择');
        }
      } catch (e) {
        // 断网 / 限流 / 解析失败：一律忽略，不影响播放。
        Log.w('LYRIC_ERROR 在线歌词失败（已忽略）guid=${track.guid} · $e');
      }
    }

    if (seq != _requestSeq) return;

    // ── 3) 都没有 ────────────────────────────────────────────
    _loading = false;
    _error = nasError;
    _doc = LyricDoc.empty;
    _docEpoch++;
    _origin = LyricOrigin.none;
    _loadedGuid = track.guid;
    _safeNotify();
    Log.i('LYRIC_LOAD 结束：无歌词 guid=${track.guid}');
  }

  /// 手动选择一条在线候选。
  ///
  /// 这是「自动匹配置信度不足」时的兜底出口：把决定权交给用户，
  /// 而不是硬绑一个可能错误的歌词。
  void applyCandidate(int index) {
    if (index < 0 || index >= _candidates.length) return;
    final OnlineLyricCandidate c = _candidates[index];
    final LyricDoc doc = _parse(c.content);
    if (doc.isEmpty) {
      Log.w('LYRIC_MANUAL 候选 #$index 解析后为空，忽略');
      return;
    }
    final String guid = _loadedGuid ?? '';
    if (guid.isNotEmpty) _cachePut(guid, doc, LyricOrigin.manual);
    _apply(guid, doc, LyricOrigin.manual);
    Log.i('LYRIC_MANUAL 用户选择候选 #$index（${c.source} '
        'score=${c.score.toStringAsFixed(2)}）lines=${doc.lines.length}');
  }

  /// 把原始歌词文本解析成 [LyricDoc]。
  ///
  /// 同时兼容「带时间轴的 LRC」与「纯文本」——`parseLrc` 对后者会产出
  /// `time == null` 的行，界面照常显示，只是不做逐句高亮。
  LyricDoc _parse(String content) {
    if (content.trim().isEmpty) return LyricDoc.empty;
    final List<LyricLine> lines = LyricDoc.parseLrc(content);
    if (lines.isEmpty) return LyricDoc.empty;
    return LyricDoc(lines: lines);
  }

  void _apply(String guid, LyricDoc doc, LyricOrigin origin) {
    _loadedGuid = guid;
    _doc = doc;
    _docEpoch++;
    _error = null;
    _origin = origin;
    _safeNotify();
  }

  void _cachePut(String guid, LyricDoc doc, LyricOrigin origin) {
    if (_cache.length >= _cacheSize && !_cache.containsKey(guid)) {
      // 淘汰最早插入的一个（LinkedHashMap 保持插入顺序）
      _cache.remove(_cache.keys.first);
    }
    _cache[guid] = _CacheEntry(doc, origin);
  }

  /// 换歌时清空当前歌词（避免上一首歌词在新歌加载完成前继续显示）。
  void clear() {
    _requestSeq++; // 让在途请求作废
    _loadedGuid = null;
    _doc = LyricDoc.empty;
    _docEpoch++;
    _error = null;
    _origin = LyricOrigin.none;
    _candidates = const <OnlineLyricCandidate>[];
    _loading = false;
    _safeNotify();
  }

  /// **仅供测试**：直接注入一份歌词，跳过网络请求。
  @visibleForTesting
  void applyForTest(String guid, LyricDoc doc) {
    _loadedGuid = guid;
    _doc = doc;
    _docEpoch++;
    _error = null;
    _origin = LyricOrigin.nas;
    _loading = false;
    _safeNotify();
  }

  bool _disposed = false;

  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
