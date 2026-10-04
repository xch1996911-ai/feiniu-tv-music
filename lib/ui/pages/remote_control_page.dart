import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/log.dart';
import '../../services/remote/qr_code.dart';
import '../../services/remote/remote_server.dart';
import '../widgets/qr_view.dart';
import '../widgets/tv_focus.dart';
import '../widgets/tv_glass.dart';

/// 电视端的「手机遥控」页面。
///
/// ## 交互设计
/// 屏幕上给出三样东西，缺一不可：
/// 1. **二维码** —— 首选路径（地址 + 配对码都在里面）；
/// 2. **配对码大字** —— 二维码扫不出来时的手输兜底（配对码同时显示成
///    6 位大写字符，用户照着敲即可）；
/// 3. **完整地址** —— 手机浏览器直接访问也行（有些相机 App 不解析 http）。
///
/// ## 为什么需要「重新生成配对码」
/// 配对码是**一次性**的：用过即失效。用户换手机、或手机清了浏览器数据，
/// 都需要一枚新码。这个按钮同时会把旧手机会话作废（需求 §七.6：
/// 新会话替换旧会话）。
///
/// ## 焦点
/// 四个按钮竖直排列、显式串联，进入页面默认落在「返回」上 ——
/// 这是电视上最不容易出错的默认值（误按 OK 只是关页面，不会改变状态）。
class RemoteControlPage extends StatefulWidget {
  const RemoteControlPage({
    super.key,
    required this.server,
    required this.onBack,
  });

  final RemoteControlServer server;
  final VoidCallback onBack;

  @override
  State<RemoteControlPage> createState() => _RemoteControlPageState();
}

class _RemoteControlPageState extends State<RemoteControlPage> {
  final FocusNode _backNode = FocusNode(debugLabel: 'remote.back');
  final FocusNode _regenNode = FocusNode(debugLabel: 'remote.regen');
  final FocusNode _copyNode = FocusNode(debugLabel: 'remote.copy');
  final FocusNode _revokeNode = FocusNode(debugLabel: 'remote.revoke');

  Timer? _ticker;

  /// 本机局域网地址（异步解析一次）。
  String? _host;

  /// 所有候选地址（第一个是当前使用的）。用于扫码失败时手动换一个。
  List<String> _hosts = const <String>[];

  /// 当前配对码（生成后保持，直到用户点「重新生成」）。

  @override
  void initState() {
    super.initState();
    unawaited(_resolveHost());
    // 1 秒刷新一次连接状态：服务端状态不在 Flutter 的通知体系里
    //（它由 Socket 事件驱动），轮询是最简单且不会漏更新的做法。
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      // ⚠️ 每轮都确保「未使用的配对码」可用（过期就续期），但**绝不撤销已配对会话**。
      //    放在定时器里而不是 build 里：build 必须保持无副作用。
      //    这样配对码过期时页面会**自动换成新码**，而不是显示一个已经失效的码 ——
      //    上一版材料里写的「过期后二维码消失」是不对的，正确的是"显示失效码且不自动续期"，
      //    现在两条都修掉了。
      widget.server.pairing.refreshCode();
      setState(() {});
    });
  }

  Future<void> _resolveHost() async {
    final List<String> ips = await RemoteControlServer.localIpv4Candidates();
    if (!mounted) return;
    setState(() {
      _hosts = ips;
      _host = ips.isEmpty ? null : ips.first;
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _backNode.dispose();
    _regenNode.dispose();
    _copyNode.dispose();
    _revokeNode.dispose();
    super.dispose();
  }

  /// 用户**主动**重新配对：这会作废已连接的手机（按钮文案已写明）。
  void _regenerate() {
    Log.i('UI 重新生成遥控配对码（主动重新配对，旧手机会被踢下线）');
    setState(() {
      widget.server.pairing.regenerateCode();
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool running = widget.server.isRunning;
    final int? port = widget.server.port;
    final String? host = _host;
    final String? code = widget.server.pairing.pairingCode;
    final bool paired = widget.server.pairing.isPaired;
    final int clients = widget.server.clientCount;

    final String url = (host == null || port == null)
        ? '(正在获取电视地址…)'
        : remotePairingUrl(host: host, port: port, code: code ?? '------');

    // 二维码容量 78 字节；URL 超长（极罕见的超长主机名）时返回 null，
    // 页面自动退化为「手输地址 + 配对码」。
    final QrCode? qr = (host == null || port == null || code == null)
        ? null
        : remotePairingQr(host: host, port: port, code: code);

    return Container(
      color: TvColors.bg,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(36),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  TvFocus(
                    focusNode: _backNode,
                    debugLabel: 'remote.back',
                    autofocus: true,
                    nextRight: _regenNode,
                    onPressed: widget.onBack,
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
                  const Text('手机遥控',
                      style: TextStyle(
                          fontSize: 26, fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 20),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    // ── 左：二维码 ────────────────────────────
                    Expanded(
                      flex: 4,
                      child: TvGlass(
                        blur: false,
                        padding: const EdgeInsets.all(20),
                        child: LayoutBuilder(
                          builder:
                              (BuildContext context, BoxConstraints c) {
                            // ⚠️ 二维码尺寸按**可用空间**算，不写死：
                            //    电视上常见逻辑视口只有 960×540（density 2.0），
                            //    写死大尺寸会把下面的说明顶出屏幕；但太小又会让
                            //    模块的物理尺寸过小（3mm 级在客厅距离下极难对焦）。
                            //    取「宽、高都装得下」的最大值，并夹在 [200, 400]。
                            const double textBlock = 86;
                            final double byHeight = c.maxHeight - textBlock;
                            final double byWidth = c.maxWidth;
                            final double side =
                                (byHeight < byWidth ? byHeight : byWidth)
                                    .clamp(200.0, 400.0);
                            return Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: <Widget>[
                                if (qr != null)
                                  QrView(code: qr, size: side)
                                else
                                  const Icon(Icons.qr_code_2,
                                      size: 200, color: TvColors.textFaint),
                                const SizedBox(height: 16),
                                const Text(
                                  '手机扫这个二维码',
                                  style: TextStyle(
                                      fontSize: 18, color: TvColors.textDim),
                                ),
                                const SizedBox(height: 6),
                                const Text(
                                  '扫不出来也可以手动输入下面的地址与配对码；\n'
                                  '尽量靠近电视扫（模块约 4mm）',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      fontSize: 14, color: TvColors.textFaint),
                                ),
                                // 提示其它候选地址：`localIpv4Candidates()` 会按
                                // 「最可能是手机可达」排序，第一个用于二维码与地址；
                                // 若电视有多张网卡（含虚拟网卡），这里给出手动兜底。
                                if (_hosts.length > 1) ...<Widget>[
                                  const SizedBox(height: 6),
                                  Text(
                                    '其它可试地址：'
                                    '${_hosts.skip(1).take(3).join(' / ')}',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                        fontSize: 13,
                                        color: TvColors.textFaint),
                                  ),
                                ],
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 20),
                    // ── 右：配对码 / 状态 / 操作 ──────────────
                    Expanded(
                      flex: 5,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          TvGlass(
                            blur: false,
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                const Text('配对码',
                                    style: TextStyle(
                                        fontSize: 16,
                                        color: TvColors.textFaint)),
                                const SizedBox(height: 6),
                                Text(
                                  code ?? '——',
                                  style: const TextStyle(
                                    fontSize: 46,
                                    letterSpacing: 10,
                                    fontWeight: FontWeight.w700,
                                    color: TvColors.text,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                const Text(
                                  '5 分钟内有效，且只能用一次。'
                                  '重新生成会让已配对的手机失效。',
                                  style: TextStyle(
                                      fontSize: 14, color: TvColors.textFaint),
                                ),
                                const SizedBox(height: 14),
                                SelectableText(
                                  url,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontFamily: 'monospace',
                                    color: TvColors.textDim,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),
                          TvGlass(
                            blur: false,
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Row(
                                  children: <Widget>[
                                    Icon(
                                      paired ? Icons.smartphone : Icons.phone_disabled,
                                      size: 20,
                                      color: paired ? TvColors.ok : TvColors.textFaint,
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      paired
                                          ? '已配对：${widget.server.pairing.sessionLabel ?? '手机'}'
                                              '${clients > 0 ? '（已连接）' : '（离线）'}'
                                          : '等待手机配对',
                                      style: const TextStyle(
                                          fontSize: 18, color: TvColors.text),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  running
                                      ? '服务运行中 · 端口 ${port ?? '-'}'
                                      : '服务未启动',
                                  style: const TextStyle(
                                      fontSize: 15, color: TvColors.textFaint),
                                ),
                                const SizedBox(height: 12),
                                const Text(
                                  '手机与电视连同一个路由器（电视网线、手机 Wi-Fi 都可以）。'
                                  '声音仍然由电视播放，手机只做遥控。',
                                  style: TextStyle(
                                      fontSize: 14,
                                      height: 1.5,
                                      color: TvColors.textFaint),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: <Widget>[
                              TvFocus(
                                focusNode: _regenNode,
                                debugLabel: 'remote.regen',
                                nextLeft: _backNode,
                                nextDown: _copyNode,
                                onPressed: _regenerate,
                                builder: (BuildContext c, TvFocusStatus s) =>
                                    TvFocusRing(
                                  status: s,
                                  radius: 999,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 20, vertical: 11),
                                  child: const Text('重新生成配对码',
                                      style: TextStyle(fontSize: 17)),
                                ),
                              ),
                              const SizedBox(width: 14),
                              TvFocus(
                                focusNode: _copyNode,
                                debugLabel: 'remote.copy',
                                nextUp: _regenNode,
                                onPressed: () {
                                  // 电视端没有剪贴板 UI，这里只把地址放大显示：
                                  // 实际上用户更可能需要它，因此点击后
                                  // 用一个对话框把地址与配对码放到最大。
                                  showDialog<void>(
                                    context: context,
                                    builder: (BuildContext ctx) => AlertDialog(
                                      backgroundColor: TvColors.panel,
                                      title: const Text('手机手动连接'),
                                      content: SelectableText(
                                        '地址：$url\n\n配对码：${code ?? '——'}',
                                        style: const TextStyle(
                                            fontSize: 20, height: 1.6),
                                      ),
                                      actions: <Widget>[
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.of(ctx).pop(),
                                          child: const Text('知道了'),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                                builder: (BuildContext c, TvFocusStatus s) =>
                                    TvFocusRing(
                                  status: s,
                                  radius: 999,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 20, vertical: 11),
                                  child: const Text('放大显示地址',
                                      style: TextStyle(fontSize: 17)),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          TvFocus(
                            focusNode: _revokeNode,
                            debugLabel: 'remote.revoke',
                            nextUp: _copyNode,
                            onPressed: () {
                              widget.server.pairing.revoke(reason: '电视端解除');
                              setState(() {});
                            },
                            builder: (BuildContext c, TvFocusStatus s) =>
                                TvFocusRing(
                              status: s,
                              radius: 999,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 10),
                              child: const Text('解除已配对的手机',
                                  style: TextStyle(
                                      fontSize: 15, color: TvColors.textFaint)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
