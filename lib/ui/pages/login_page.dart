import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../repositories/auth_repository.dart';

/// 登录页（Phase 1 临时验证 UI）。
/// 扫码登录在 Phase 5 实现。
///
/// ## Android TV 的 D-pad 焦点（真实故障：遥控器下键切不到下一个输入框）
///
/// 现象：在 NAS 地址框输入完，按遥控器「下」键，焦点**移不到**用户名 / 密码框。
///
/// 根因**不在本页**，而在 Flutter 的默认按键绑定：
/// `WidgetsApp` 把方向键绑成 `DirectionalFocusIntent`，而它的
/// `ignoreTextFields` 默认是 **`true`** —— 语义是「当前焦点在 `EditableText`
/// 里时忽略方向键，交给文本框自己处理」。可单行文本框里上下键既不能移动
/// 光标、又不再触发焦点遍历，事件被静默吞掉，表现就是「按键没反应」。
///
/// 修法：本页用 `Shortcuts` 覆盖这两个方向键，显式传
/// `ignoreTextFields: false`。本页三个输入框全是单行，不存在「用上下键在
/// 多行文本里移光标」的诉求，因此覆盖是安全的。
///
/// 另配 `textInputAction` + `onSubmitted`：遥控器 OK 键在输入态会走 IME 的
/// 「下一个 / 完成」，对电视用户比方向键更顺手 —— 两条路都留着。
///
/// ## 为什么把「阶段 / 耗时 / 实际地址 / 原始错误」画在屏幕上
///
/// 真实故障：登录时界面停在「连接中」，既不成功也不报错，而电视上没有 adb、
/// 也拿不到 `boot.log`。此时**屏幕上能读到的东西就是唯一的证据**，所以本页
/// 刻意显示：
/// - 当前阶段（读取设备标识 / 请求登录 / 保存会话）—— 直接指出卡在哪一步；
/// - 已等待秒数 —— 区分「慢」与「死等」；
/// - 实际请求地址（已补 `http://`）—— 地址写错时一眼可见；
/// - 错误的 `kind` 与原始 `cause` —— 不用猜是网络、凭据还是解析问题。
class LoginPage extends StatefulWidget {
  final VoidCallback onLoggedIn;

  const LoginPage({super.key, required this.onLoggedIn});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _host = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();

  // 焦点节点显式建在 State 里：`onSubmitted` 要靠它把焦点交给下一个框；
  // 在 build 里 new 会泄漏，且每次重建都会丢焦点。
  final _hostFocus = FocusNode();
  final _userFocus = FocusNode();
  final _passFocus = FocusNode();

  bool _remember = false;
  bool _busy = false;
  String? _error;

  /// 错误的原始信息（`AppError.kind` + `cause`），只在排错时看，故用弱化样式。
  String? _detail;

  /// 免登录探测的结果（成功时的提示）。
  String? _notice;

  /// 当前阶段文案（由 `AuthRepository.login` 的 `onStage` 回调更新）。
  String? _stage;

  /// 阶段内已等待秒数。用于区分「网络慢」与「永久挂起」。
  int _elapsed = 0;

  Timer? _ticker;

  /// 实际将要请求的地址（归一化后的 baseUrl）。
  String? _target;

  @override
  void dispose() {
    _ticker?.cancel();
    _host.dispose();
    _user.dispose();
    _pass.dispose();
    _hostFocus.dispose();
    _userFocus.dispose();
    _passFocus.dispose();
    super.dispose();
  }

  void _startTicker() {
    _ticker?.cancel();
    _elapsed = 0;
    _ticker = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _elapsed++);
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  Future<void> _submit() async {
    final host = _host.text.trim();
    final username = _user.text.trim();
    final password = _pass.text;
    if (host.isEmpty || username.isEmpty || password.isEmpty) {
      setState(() {
        _error = '请填写 NAS 地址、用户名与密码';
        _detail = null;
      });
      return;
    }
    // context 相关的东西必须在 await 之前取完（use_build_context_synchronously）。
    final auth = context.read<AuthRepository>();
    setState(() {
      _busy = true;
      _error = null;
      _detail = null;
      _notice = null;
      _stage = '准备中…';
      _target = auth.normalizeHost(host);
    });
    _startTicker();

    final res = await auth.login(
      host: host,
      username: username,
      password: password,
      rememberPassword: _remember,
      onStage: (String stage) {
        if (mounted) setState(() => _stage = stage);
      },
    );
    if (!mounted) return;
    _stopTicker();
    if (res.isErr) {
      setState(() {
        _busy = false;
        _stage = null;
        _error = res.error.message;
        _detail = 'kind=${res.error.kind.name}'
            '${res.error.cause == null ? '' : '\n${res.error.cause}'}';
      });
      return;
    }
    setState(() {
      _busy = false;
      _stage = null;
    });
    widget.onLoggedIn();
  }

  /// 免登录连通性探测：判断「地址 / 网络」是否通，与凭据无关。
  ///
  /// 这是电视端唯一能在**屏幕上**直接读出网络结论的手段。
  Future<void> _probe() async {
    final host = _host.text.trim();
    if (host.isEmpty) {
      setState(() {
        _error = '请先填写 NAS 地址';
        _detail = null;
      });
      return;
    }
    final auth = context.read<AuthRepository>();
    setState(() {
      _busy = true;
      _error = null;
      _detail = null;
      _notice = null;
      _stage = '测试连通性…';
      _target = auth.normalizeHost(host);
    });
    _startTicker();

    final res = await auth.probe(host);
    if (!mounted) return;
    _stopTicker();
    setState(() {
      _busy = false;
      _stage = null;
      if (res.isErr) {
        _error = res.error.message;
        _detail = 'kind=${res.error.kind.name}'
            '${res.error.cause == null ? '' : '\n${res.error.cause}'}';
      } else {
        _notice = res.value;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('连接飞牛 NAS')),
      // 见类注释：默认的 DirectionalFocusIntent 会把「焦点在输入框里时的
      // 上下键」静默吞掉，必须在这里显式关掉 ignoreTextFields。
      body: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(
            TraversalDirection.down,
            ignoreTextFields: false,
          ),
          SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(
            TraversalDirection.up,
            ignoreTextFields: false,
          ),
        },
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: SizedBox(
              width: 600,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('飞牛 TV 音乐 · Phase 1',
                      style:
                          TextStyle(fontSize: 26, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _host,
                    focusNode: _hostFocus,
                    autofocus: true,
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => _userFocus.requestFocus(),
                    decoration: const InputDecoration(
                      labelText: 'NAS 地址（含端口）',
                      // hint 里的 scheme 只是示范；即使漏写也会自动补 http://。
                      hintText: '192.168.1.10:5666',
                      helperText: '漏写 http:// 也没关系，会自动补上',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _user,
                    focusNode: _userFocus,
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => _passFocus.requestFocus(),
                    decoration: const InputDecoration(
                      labelText: '用户名',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _pass,
                    focusNode: _passFocus,
                    obscureText: true,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) {
                      unawaited(_submit());
                    },
                    decoration: const InputDecoration(
                      labelText: '密码',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    value: _remember,
                    onChanged: (v) => setState(() => _remember = v ?? false),
                    title: const Text('记住密码并自动重新登录（仅保存 sha256 哈希）'),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                  ),
                  if (_stage != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      '$_stage 已等待 $_elapsed 秒',
                      style: const TextStyle(
                          fontSize: 17, color: Color(0xFF8AB4F8)),
                    ),
                  ],
                  if (_target != null && _target!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text('实际请求地址：$_target',
                        style: const TextStyle(
                            fontSize: 15, color: Colors.white54)),
                  ],
                  if (_notice != null) ...[
                    const SizedBox(height: 8),
                    Text(_notice!,
                        style: const TextStyle(
                            fontSize: 18, color: Color(0xFF54D68A))),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!,
                        style: const TextStyle(
                            fontSize: 20, color: Colors.redAccent)),
                  ],
                  if (_detail != null) ...[
                    const SizedBox(height: 6),
                    // 原始错误：电视上没有 adb，这一块是唯一能带回来的证据。
                    // 用等宽字体 + 弱化颜色，避免吓到普通用户。
                    SelectableText(
                      _detail!,
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        fontFamily: 'monospace',
                        color: Color(0xFFFFB4AB),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: _busy ? null : _submit,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: Text(_busy ? '连接中…' : '连接并登录',
                        style: const TextStyle(fontSize: 20)),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _busy ? null : _probe,
                    child: const Text('只测试连接（不需账号和密码）',
                        style: TextStyle(fontSize: 18)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
