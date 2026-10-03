import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/boot_log.dart';
import '../../core/branding.dart';
import '../../core/diagnostics.dart';
import '../widgets/tv_focus.dart';
import '../widgets/tv_glass.dart';

/// 诊断页 —— **所有技术细节的唯一落点**。
///
/// ## 为什么必须独立成页
///
/// V4 把「为什么没有内容」的技术解释直接印在正常页面上（风格页解释
/// `genres` 字段为空、最近页解释没有历史接口），实机截图里这些文字占了
/// 大半个屏幕。它们对排错有用、对用户无用。
///
/// V5 的规则：正常页面只留一句短文案；异常原文、接口路径、请求耗时、
/// 插件初始化结果一律登记到 [Diagnostics]，只在本页呈现。
///
/// 页面结构固定为四段，方便用户拍照回传：
/// 1. **应用**：名称、版本、启动次数；
/// 2. **运行环境**：Dart / 系统 / 日志文件路径；
/// 3. **当前状态**：各子系统自报的键值（由 [Diagnostics.note] 写入）；
/// 4. **事件与日志**：流水事件 + 启动日志尾部。
///
/// ## 入口
/// - 启动页右下角「诊断」；
/// - 侧栏底部「诊断与帮助」。
///
/// 本页**不含任何凭据**，也不显示 NAS 地址与查询参数之外的请求细节 ——
/// 登记时由调用方保证（见 [Diagnostics] 的说明）。
class DiagnosticsPage extends StatelessWidget {
  const DiagnosticsPage({super.key, this.embedded = false, this.onRebuildIndex});

  /// 嵌入模式：由启动页/Shell 直接作为 body 使用时不画自己的背景与返回按钮。
  final bool embedded;

  /// 手动「重建曲库索引」（V5 需求 §三-A.6 / §三-B.6）。
  ///
  /// 刻意把按钮放在**诊断页**而不是首页：需求说「正常使用不依赖用户执行」，
  /// 主界面不该常年挂着一个只会让用户困惑的「重建索引」按钮；
  /// 但真需要时（换 NAS、索引半成品、怀疑统计不对）它必须够得着。
  final Future<void> Function()? onRebuildIndex;

  @override
  Widget build(BuildContext context) {
    final Widget body = _DiagnosticsBody(
      embedded: embedded,
      onRebuildIndex: onRebuildIndex,
    );

    if (embedded) return body;

    return Scaffold(
      backgroundColor: TvColors.bg,
      body: SafeArea(child: body),
    );
  }
}

class _DiagnosticsBody extends StatelessWidget {
  const _DiagnosticsBody({required this.embedded, this.onRebuildIndex});

  final bool embedded;
  final Future<void> Function()? onRebuildIndex;

  static const int _logTail = 30;
  static const int _eventTail = 24;

  @override
  Widget build(BuildContext context) {
    final List<String> logs = BootLog.lines;
    final List<String> logTail =
        logs.length <= _logTail ? logs : logs.sublist(logs.length - _logTail);
    final List<String> events = Diagnostics.events;
    final List<String> eventTail = events.length <= _eventTail
        ? events
        : events.sublist(events.length - _eventTail);

    return ListView(
      padding: EdgeInsets.fromLTRB(embedded ? 0 : 48, 32, embedded ? 0 : 48, 48),
      children: <Widget>[
        if (!embedded) ...<Widget>[
          Row(
            children: <Widget>[
              TvFocus(
                debugLabel: 'diag.back',
                onPressed: () => Navigator.of(context).maybePop(),
                builder: (BuildContext c, TvFocusStatus s) => TvFocusRing(
                  status: s,
                  radius: 999,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 10),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(Icons.arrow_back, size: 22, color: TvColors.text),
                      SizedBox(width: 8),
                      Text('返回', style: TextStyle(fontSize: 18)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 20),
              const Text('诊断与帮助',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 24),
        ],
        _Section(
          title: '应用',
          rows: <String, String>{
            '显示名称': kAppName,
            '版本': kAppVersion,
            '本次启动尝试': '${BootLog.bootAttempts} 次'
                '${BootLog.safeMode ? '（已达安全模式阈值）' : ''}',
          },
        ),
        _Section(
          title: '运行环境',
          rows: <String, String>{
            'Dart': _dartVersion(),
            '系统': _osVersion(),
            '日志文件': BootLog.path,
          },
        ),
        _Section(
          title: '当前状态',
          rows: Diagnostics.notes.isEmpty
              ? <String, String>{'(暂无)': ''}
              : Diagnostics.notes,
        ),
        _Block(
          title: '事件流水（最新在最后）',
          text: eventTail.isEmpty ? '(暂无)' : eventTail.join('\n'),
          monospace: true,
        ),
        _Block(
          title: '启动日志尾部（最新在最后）',
          text: logTail.isEmpty ? '(暂无)' : logTail.join('\n'),
          monospace: true,
        ),
        if (onRebuildIndex != null) ...<Widget>[
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              TvFocus(
                debugLabel: 'diag.rebuild',
                onPressed: () => unawaited(onRebuildIndex!()),
                builder: (BuildContext c, TvFocusStatus s) => TvFocusRing(
                  status: s,
                  radius: 999,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 22, vertical: 11),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(Icons.refresh, size: 20, color: TvColors.text),
                      SizedBox(width: 8),
                      Text('重建曲库索引', style: TextStyle(fontSize: 17)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 16),
              const Expanded(
                child: Text(
                  '会重新读取全部分页并覆盖本地索引；'
                  '收藏、历史、风格确认与播放偏好不受影响。',
                  style: TextStyle(fontSize: 14, color: TvColors.textFaint),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        const Text(
          '提示：以上内容不会出现在正常播放界面。排查问题时拍照回传即可。',
          style: TextStyle(fontSize: 15, color: TvColors.textFaint),
        ),
      ],
    );
  }

  static String _dartVersion() {
    try {
      return Platform.version.split(' ').first;
    } catch (_) {
      return '(未知)';
    }
  }

  static String _osVersion() {
    try {
      return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    } catch (_) {
      return '(未知)';
    }
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.rows});

  final String title;
  final Map<String, String> rows;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: TvGlass(
        radius: 14,
        blur: false,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title,
                style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                    color: TvColors.textDim)),
            const SizedBox(height: 10),
            for (final MapEntry<String, String> e in rows.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(
                      width: 150,
                      child: Text(e.key,
                          style: const TextStyle(
                              fontSize: 16, color: TvColors.textFaint)),
                    ),
                    Expanded(
                      child: Text(
                        e.value,
                        style: const TextStyle(
                            fontSize: 16,
                            color: TvColors.text,
                            height: 1.35),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({
    required this.title,
    required this.text,
    this.monospace = false,
  });

  final String title;
  final String text;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title,
              style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                  color: TvColors.textDim)),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF101018),
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(
              text,
              style: TextStyle(
                fontSize: 15,
                height: 1.5,
                fontFamily: monospace ? 'monospace' : null,
                color: monospace ? const Color(0xFF9FE8B5) : TvColors.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
