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

  @override
  void dispose() {
    _host.dispose();
    _user.dispose();
    _pass.dispose();
    _hostFocus.dispose();
    _userFocus.dispose();
    _passFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final host = _host.text.trim();
    final username = _user.text.trim();
    final password = _pass.text;
    if (host.isEmpty || username.isEmpty || password.isEmpty) {
      setState(() => _error = '请填写 NAS 地址、用户名与密码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final auth = context.read<AuthRepository>();
    final res = await auth.login(
      host: host,
      username: username,
      password: password,
      rememberPassword: _remember,
    );
    if (!mounted) return;
    if (res.isErr) {
      setState(() {
        _busy = false;
        _error = res.error.message;
      });
      return;
    }
    setState(() => _busy = false);
    widget.onLoggedIn();
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
          child: SizedBox(
            width: 600,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('飞牛 TV 音乐 · Phase 1',
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600)),
                const SizedBox(height: 24),
                TextField(
                  controller: _host,
                  focusNode: _hostFocus,
                  autofocus: true,
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => _userFocus.requestFocus(),
                  decoration: const InputDecoration(
                    labelText: 'NAS 地址（含端口）',
                    hintText: 'http://192.168.1.10:5666',
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
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: const TextStyle(color: Colors.redAccent)),
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
