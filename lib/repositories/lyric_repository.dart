import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/log.dart';
import '../domain/lyric.dart';
import '../domain/track.dart';
import 'music_repository.dart';

/// 歌词仓储：只加载**当前歌曲**的歌词，并给出「当前该高亮哪一行」。
///
/// ## 为什么要单独一个仓储
/// 1. 曲库可能有几千首，**绝不能一次加载整个曲库的歌词**
///    （歌词接口按 `trackGUID` 单曲查询，全库拉会打爆请求）；
/// 2. 歌词跟随播放位置需要高频计算，放进 UI 会让 UI 变成数据层；
/// 3. 换歌时必须能取消上一首的加载，避免「上一首的歌词覆盖当前首」。
class LyricRepository extends ChangeNotifier {
  final MusicRepository _music;

  LyricRepository(this._music);

  /// 当前已加载歌词的曲目 guid；null = 未加载任何歌词。
  String? _loadedGuid;

  LyricDoc _doc = LyricDoc.empty;

  /// 正在加载。
  bool _loading = false;

  /// 加载失败（界面显示「暂无歌词」而不是报错）。
  String? _error;

  /// 上一次请求的序号：只有最新一次的结果会被采纳。
  int _requestSeq = 0;

  /// 小缓存：避免来回切歌反复请求同一首（容量很小，按插入顺序淘汰）。
  final Map<String, LyricDoc> _cache = <String, LyricDoc>{};
  static const int _cacheSize = 20;

  LyricDoc get doc => _doc;
  bool get isLoading => _loading;
  String? get error => _error;
  String? get loadedGuid => _loadedGuid;
  bool get isEmpty => _doc.isEmpty;

  /// 取 [position] 时刻应当高亮的行下标；无歌词返回 -1。
  ///
  /// 用「最后一个 time <= position 的行」判定 —— 这是 LRC 的标准语义。
  /// 逐字歌词（karaoke）不在支持范围。
  int activeLineIndex(Duration position) {
    final lines = _doc.lines;
    if (lines.isEmpty) return -1;
    var lo = 0;
    var hi = lines.length - 1;
    var ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final t = lines[mid].time;
      if (t == null) {
        // 无时间轴的行不算命中，继续往前找
        hi = mid - 1;
        continue;
      }
      if (t <= position) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  /// 加载指定歌曲的歌词。
  ///
  /// [force] 为 true 时忽略缓存（用于「歌词没出来」的手动重试）。
  ///
  /// ## 竞态防护
  /// 每次调用都会让 [_requestSeq] 自增；请求返回时若自己已不是最新，
  /// 结果**直接丢弃** —— 否则快速切歌会出现「上一首歌词显示在当前首」。
  Future<void> load(Track track, {bool force = false}) async {
    if (track.guid.isEmpty) return;

    if (!force) {
      final cached = _cache[track.guid];
      if (cached != null) {
        _apply(track.guid, cached);
        return;
      }
    }

    final seq = ++_requestSeq;
    _loading = true;
    _error = null;
    _safeNotify();
    Log.i('LYRIC_LOAD guid=${track.guid}');

    final res = await _music.getLyrics(track.guid);

    // 已有更新的请求 → 丢弃本次结果
    if (seq != _requestSeq) {
      Log.i('LYRIC_LOAD 丢弃过期结果 guid=${track.guid}');
      return;
    }
    _loading = false;

    if (res.isErr) {
      // 歌词失败**绝不能影响播放**：只标记空歌词，界面显示「暂无歌词」。
      Log.w('LYRIC_ERROR guid=${track.guid} kind=${res.error.kind} ${res.error.message}');
      _error = res.error.message;
      _doc = LyricDoc.empty;
      _loadedGuid = track.guid;
      _safeNotify();
      return;
    }

    final doc = res.value;
    _cachePut(track.guid, doc);
    _apply(track.guid, doc);
    Log.i('LYRIC_LOAD 完成 guid=${track.guid} lines=${doc.lines.length}');
  }

  void _apply(String guid, LyricDoc doc) {
    _loadedGuid = guid;
    _doc = doc;
    _error = null;
    _safeNotify();
  }

  void _cachePut(String guid, LyricDoc doc) {
    if (_cache.length >= _cacheSize) {
      // 淘汰最早插入的一个（LinkedHashMap 保持插入顺序）
      _cache.remove(_cache.keys.first);
    }
    _cache[guid] = doc;
  }

  /// 换歌时清空当前歌词（避免上一首歌词在新歌加载完成前继续显示）。
  void clear() {
    _requestSeq++; // 让在途请求作废
    _loadedGuid = null;
    _doc = LyricDoc.empty;
    _error = null;
    _loading = false;
    _safeNotify();
  }

  /// **仅供测试**：直接注入一份歌词，跳过网络请求。
  ///
  /// 设备上恒为测试专用入口（生产路径请用 [load]）。
  @visibleForTesting
  void applyForTest(String guid, LyricDoc doc) {
    _loadedGuid = guid;
    _doc = doc;
    _error = null;
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
