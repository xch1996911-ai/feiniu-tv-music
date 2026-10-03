import 'package:flutter/foundation.dart';

import 'boot_log.dart';

/// 诊断信息登记中心 —— **技术细节的唯一去处**。
///
/// ## 为什么要有它（V5 明确要求）
///
/// V4 把「实现细节」直接画在了正常页面上，实机截图里能看到：
///
/// - 风格页：「飞牛曲目的 `genres` 字段在当前曲库里是空的，因此这个页面
///   暂时没有内容 —— 这不是加载失败，也不会把全部歌曲硬塞进『未知风格』。」
/// - 最近页：「飞牛没有提供播放历史接口，这里的记录由电视本机保存，
///   从『音乐库』里挑一首开始播放，这里就会留下痕迹。」
///
/// 这些文字**对排错很有价值、对用户毫无价值**：电视观看距离下它们占掉
/// 大半个屏幕，而且每一句都在解释「我们做不到什么」。
///
/// V5 的规则因此是：
/// - 正常页面只出现**短文案**（「暂无最近播放」「暂无歌曲」）；
/// - 任何技术解释、异常原文、接口路径、请求耗时一律走本类登记，
///   只在诊断页（`lib/ui/pages/diagnostics_page.dart`）呈现；
/// - 日志文件仍然完整落盘（[BootLog]），两者互不替代。
///
/// ## 两类内容
/// - [note]：**当前状态**，键值对，同一个 key 反复写入会覆盖（例如
///   「媒体会话 = 已就绪」「曲库索引 = 已完成 2796 首」）；
/// - [event]：**流水事件**，按时间追加，用于还原「刚才发生了什么」
///   （例如「歌词 NAS 12s 超时 → 转在线」）。
///
/// ⚠️ **绝不能写入凭据**：不做脱敏也不判断，调用方必须自己保证
/// 不把 token / 密码 / 完整 URL 带查询参数写进来（V5 §七.9 明确要求）。
class Diagnostics {
  Diagnostics._();

  static final Map<String, String> _notes = <String, String>{};
  static final List<String> _events = <String>[];

  /// 事件流水上限（诊断页只展示尾部，防止长时间运行后无限增长）。
  static const int _maxEvents = 200;

  /// 写入/覆盖一条**状态**。
  static void note(String key, String value) {
    _notes[key] = value;
    BootLog.mark('[诊断] $key = $value');
  }

  /// 追加一条**事件**。
  static void event(String message) {
    _events.add(message);
    if (_events.length > _maxEvents) {
      _events.removeRange(0, _events.length - _maxEvents);
    }
    BootLog.mark('[事件] $message');
  }

  /// 当前状态快照（只读）。
  static Map<String, String> get notes => Map<String, String>.unmodifiable(_notes);

  /// 事件流水（只读）。最新在最后。
  static List<String> get events => List<String>.unmodifiable(_events);

  /// 清空（仅测试使用；正常运行不清）。
  @visibleForTesting
  static void reset() {
    _notes.clear();
    _events.clear();
  }
}
