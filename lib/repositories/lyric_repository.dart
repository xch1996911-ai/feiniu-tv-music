import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/exceptions.dart';
import '../core/log.dart';
import '../core/result.dart';
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

  /// 单次歌词请求的硬上限。
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

  /// 小缓存：避免来回切歌反复请求同一首（容量很小，按插入顺序淘汰）。
  final Map<String, LyricDoc> _cache = <String, LyricDoc>{};
  static const int _cacheSize = 20;

  LyricDoc get doc => _doc;
  bool get isLoading => _loading;
  String? get error => _error;
  String? get loadedGuid => _loadedGuid;
  bool get isEmpty => _doc.isEmpty;

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
  /// ## 为什么改成线性扫描（原来用二分）
  /// 旧实现假定「`time == null` 的行一定连续地排在前面」，二分一踩到 null
  /// 就往前半区收缩。而 `parseLrc` 里无时间轴的行是按 `Duration.zero` 参与排序的，
  /// 与真正的 `[00:00.00]` 行先后顺序**不确定**，于是二分会漏掉合法行 ——
  /// 表现为「歌词高亮跳错句 / 停在第一句不动」。
  ///
  /// 歌词只有几百行、每 500ms 才调一次，线性扫完全够用，且对
  /// 「有空行 / 有 offset / 顺序不完美」都天然正确。
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
  /// 2. 未命中缓存时**先清空当前歌词再发请求**：否则新歌词回来之前，
  ///    界面上仍然是上一首的歌词（真实故障：切换上下首后歌词文不对题）。
  Future<void> load(Track track, {bool force = false}) async {
    if (track.guid.isEmpty) return;

    if (!force) {
      final cached = _cache[track.guid];
      if (cached != null) {
        Log.i('LYRIC_LOAD 命中缓存 guid=${track.guid} lines=${cached.lines.length}');
        _apply(track.guid, cached);
        return;
      }
    }

    final seq = ++_requestSeq;
    _loadedGuid = track.guid;
    _doc = LyricDoc.empty;
    _docEpoch++;
    _error = null;
    _loading = true;
    _safeNotify();
    Log.i('LYRIC_LOAD guid=${track.guid}');

    Result<LyricDoc> res;
    try {
      res = await _music.getLyrics(track.guid).timeout(requestTimeout);
    } catch (e, st) {
      Log.w('LYRIC_ERROR 请求超时或异常 guid=${track.guid} · $e');
      res = Result<LyricDoc>.err(AppError(
        '歌词请求失败：$e',
        kind: ErrorKind.network,
        cause: e,
        stack: st,
      ));
    }

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
      _docEpoch++;
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
    _docEpoch++;
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
    _docEpoch++;
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
    _docEpoch++;
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
