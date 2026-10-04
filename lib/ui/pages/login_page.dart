import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/branding.dart';
import '../../core/log.dart';
import '../../repositories/auth_repository.dart';
import '../../services/text_input_bridge.dart';
import '../widgets/tv_focus.dart';
import '../widgets/tv_keyboard.dart';

/// 登录页（连接飞牛 NAS）。
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
/// ## 小米电视 S Pro 2025 不能输入（V6 修复）
///
/// 现象：能选中输入框，但**按 OK 系统软键盘不弹出**，无法输入任何字符 ⇒ 无法登录。
///
/// 这是三件事叠加的结果，本页按「层层兜底」处理，缺一层都不算修好：
///
/// 1. **系统键盘是否弹出不由 App 决定**（取决于电视 ROM 有没有可用 IME、
///    是否愿意给非触屏设备显示）。因此获得焦点后**显式**再调一次
///    `InputMethodManager.showSoftInput`（见 [TextInputBridge]）；
/// 2. 显式调用失败或**等待 [imeProbeDelay] 后系统键盘仍未出现**
///    （判据：`viewInsets.bottom` 仍为 0，见 [didChangeMetrics]）→
///    **自动打开应用内遥控器键盘**，用户不需要知道发生了什么就能继续输入；
/// 3. 另有常驻入口「打开遥控器键盘」：任何时候都能手动唤起，
///    不依赖计时器，也不依赖系统输入法。
///
/// 键盘打开时**表单整块被 `ExcludeFocus` 排除**，方向键不会跑到表单上；
/// Back 键先关闭键盘（[PopScope]），关闭后焦点显式还回正在编辑的字段。
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

  /// 「等了多久算系统键盘没出来」——超过就上应用内键盘。
  ///
  /// 1.2s 的取舍：小于该值时部分 ROM 的 IME 还在启动（会闪一下两层键盘）；
  /// 大于该值时用户在遥控器上已经等得心烦。
  ///
  /// 公开为**测试可读**常量：测试要按这个时长推进假时钟来验证兜底路径。
  static const Duration imeProbeDelay = Duration(milliseconds: 1200);

  @override
  State<LoginPage> createState() => _LoginPageState();
}

/// 三个输入字段。
enum _Field { host, user, pass }

class _LoginPageState extends State<LoginPage> with WidgetsBindingObserver {
  final _host = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();

  // 焦点节点显式建在 State 里：`onSubmitted` 要靠它把焦点交给下一个框；
  // 在 build 里 new 会泄漏，且每次重建都会丢焦点。
  final _hostFocus = FocusNode(debugLabel: 'login.host');
  final _userFocus = FocusNode(debugLabel: 'login.user');
  final _passFocus = FocusNode(debugLabel: 'login.pass');

  /// 表单滚动控制器：键盘弹出时要把正在编辑的字段滚到可见区域。
  final ScrollController _formScroll = ScrollController();

  /// 三个字段的定位锚点（`Scrollable.ensureVisible` 用）。
  final Map<_Field, GlobalKey> _fieldKeys = <_Field, GlobalKey>{
    _Field.host: GlobalKey(),
    _Field.user: GlobalKey(),
    _Field.pass: GlobalKey(),
  };

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

  // ── 输入法相关状态 ─────────────────────────────────────────

  /// 正在编辑哪个字段（应用内键盘据此决定写哪个 controller）。
  _Field? _editing;

  /// 应用内遥控器键盘是否打开。
  bool _keyboardOpen = false;

  /// 键盘是**自动**打开的吗（系统键盘没弹出来）——只影响提示文案。
  bool _keyboardAuto = false;

  /// 系统软键盘当前是否可见（由 `viewInsets.bottom` 判定）。
  bool _systemKeyboard = false;

  /// 密码框是否掩码（应用内键盘的「显示/隐藏」会改它）。
  bool _passObscure = true;

  /// 与 [LoginPage.imeProbeDelay] 同值（类内引用更短）。
  static const Duration _imeProbeDelay = LoginPage.imeProbeDelay;

  Timer? _imeProbe;

  /// 已经为该字段**自动**打开过一次键盘。
  ///
  /// ⚠️ 没有这个闸门会立刻出现一个更难看的 bug：用户按「完成」收起键盘后，
  /// 焦点回到字段 → 字段焦点监听再次触发 → 1.2 秒后键盘又自己弹出来，
  /// 用户会觉得「关不掉」。字段失焦时清空，因此换个字段仍会重新探测。
  _Field? _autoOpenedFor;

  /// 本机输入法摘要（**非敏感**，仅真机排障时显示）。
  String? _imeInfo;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _hostFocus.addListener(() => _onFocusChanged(_Field.host));
    _userFocus.addListener(() => _onFocusChanged(_Field.user));
    _passFocus.addListener(() => _onFocusChanged(_Field.pass));
    // 输入法可用性：只记日志/存字符串，失败静默（电视上不允许崩）。
    unawaited(TextInputBridge.imeInfo().then((String? info) {
      if (!mounted || info == null) return;
      Log.i('LOGIN_IME 输入法信息：$info');
      setState(() => _imeInfo = info);
    }));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _imeProbe?.cancel();
    _ticker?.cancel();
    _formScroll.dispose();
    _host.dispose();
    _user.dispose();
    _pass.dispose();
    _hostFocus.dispose();
    _userFocus.dispose();
    _passFocus.dispose();
    super.dispose();
  }

  // ── 输入法 / 键盘编排 ─────────────────────────────────────

  TextEditingController _controllerOf(_Field f) => switch (f) {
        _Field.host => _host,
        _Field.user => _user,
        _Field.pass => _pass,
      };

  FocusNode _focusOf(_Field f) => switch (f) {
        _Field.host => _hostFocus,
        _Field.user => _userFocus,
        _Field.pass => _passFocus,
      };

  String _labelOf(_Field f) => switch (f) {
        _Field.host => 'NAS 地址（含端口）',
        _Field.user => '用户名',
        _Field.pass => '密码',
      };

  /// 焦点转移的统一处理：滚动到可见 + 显式唤起系统键盘 + 起「探测」计时器。
  void _onFocusChanged(_Field f) {
    if (!_focusOf(f).hasFocus) {
      // 失焦：允许下次进来重新探测（否则换成别的字段后就不再兜底了）。
      if (_autoOpenedFor == f) _autoOpenedFor = null;
      _imeProbe?.cancel();
      return;
    }
    if (_keyboardOpen) return; // 应用内键盘打开时，底层焦点变化不触发新一轮探测
    _editing = f;
    _scrollFieldIntoView(f);
    unawaited(_askSystemKeyboard(f));
    _imeProbe?.cancel();
    // 该字段已经自动开过一次（用户手动关闭过）→ 不再自动弹回来。
    if (_autoOpenedFor == f) return;
    _imeProbe = Timer(_imeProbeDelay, () {
      if (!mounted) return;
      if (_keyboardOpen) return;
      if (_editing != f) return;
      if (!_focusOf(f).hasFocus) return;
      if (_systemKeyboard) return; // 系统键盘确实弹出来了，不必兜底
      Log.w('LOGIN_IME 等待 ${_imeProbeDelay.inMilliseconds}ms 系统键盘未出现 → '
          '自动打开遥控器键盘（字段=${f.name}）');
      _openKeyboard(f, auto: true);
    });
  }

  /// 显式再唤一次系统软键盘（Flutter 自己的调用可能早于焦点稳定）。
  Future<void> _askSystemKeyboard(_Field f) async {
    final bool ok = await TextInputBridge.showSoftKeyboard();
    Log.i('LOGIN_IME 显式唤起系统键盘（字段=${f.name}）→ $ok');
  }

  void _scrollFieldIntoView(_Field f) {
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      final BuildContext? ctx = _fieldKeys[f]?.currentContext;
      if (ctx == null) return;
      // 焦点在屏幕上必须可见：键盘（系统或应用内）都会压缩可用高度。
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 180),
        alignment: 0.35,
      );
    });
  }

  /// 打开应用内遥控器键盘（[auto] 表示是「系统键盘没出来」的兜底）。
  void _openKeyboard(_Field f, {bool auto = false}) {
    _imeProbe?.cancel();
    if (auto) _autoOpenedFor = f;
    // 系统键盘若也在，先收掉，避免两层键盘叠起来。
    unawaited(TextInputBridge.hideSoftKeyboard());
    setState(() {
      _editing = f;
      _keyboardOpen = true;
      _keyboardAuto = auto;
    });
    // 已打开的字段跟随后续焦点变化（用户用 D-pad 换字段时不关键盘）。
    _scrollFieldIntoView(f);
  }

  /// 关闭应用内键盘，并把焦点**显式**还回正在编辑的字段。
  ///
  /// ⚠️ 顺序不能反：键盘打开时表单被 `ExcludeFocus` 排除，
  /// 此时 `requestFocus` 只会落到最近的可用祖先（表现是「焦点掉到 scope、方向键全失灵」）。
  /// 必须先 setState 解除排除，再在下一帧请求焦点。
  void _closeKeyboard() {
    final _Field? f = _editing;
    if (!_keyboardOpen) return;
    setState(() {
      _keyboardOpen = false;
      _keyboardAuto = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      final _Field? target = f ?? _Field.host;
      _focusOf(target).requestFocus();
      _scrollFieldIntoView(target);
    });
  }

  /// 手动入口：为「当前有焦点的字段」打开键盘（没有就默认地址框）。
  void _openKeyboardManually() {
    final _Field target = _editing ??
        (_hostFocus.hasFocus
            ? _Field.host
            : _userFocus.hasFocus
                ? _Field.user
                : _passFocus.hasFocus
                    ? _Field.pass
                    : _Field.host);
    _openKeyboard(target);
  }

  /// 系统键盘出现 / 消失（`viewInsets.bottom` 变化）。
  ///
  /// 这是**唯一**判断「系统键盘到底弹没弹」的可靠信号：
  /// 电视 ROM 上 `showSoftInput` 的返回值并不可信。
  @override
  void didChangeMetrics() {
    // ⚠️ 刻意不写 `Iterable<FlutterView>`：`FlutterView` 在 dart:ui 里，
    //    这里不额外导入，靠类型推断（少一个 import 就少一处版本差异风险）。
    final double bottom =
        WidgetsBinding.instance.platformDispatcher.views.isEmpty
            ? 0
            : WidgetsBinding
                .instance.platformDispatcher.views.first.viewInsets.bottom;
    final bool visible = bottom > 0;
    if (visible == _systemKeyboard) return;
    _systemKeyboard = visible;
    if (!mounted) return;
    Log.i('LOGIN_IME 系统键盘 ${visible ? '已显示' : '已收起'}（inset=$bottom）');
    if (visible && _keyboardOpen) {
      // 系统键盘既然工作了，就把应用内键盘收掉（只留一层）。
      _closeKeyboard();
      return;
    }
    setState(() {});
  }

  // ── 登录 ─────────────────────────────────────────────────

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

  // ── 渲染 ─────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final MediaQueryData mq = MediaQuery.of(context);
    // 应用内键盘高度：占屏幕的一小半多一点，最多 370px（4K 逻辑视口下不显得夸张）。
    // ⚠️ 下限 300：键盘内部按可用高度反推键高，太矮会让「完成」那一行被裁掉。
    //    注意常量写成 double（`370.0`）：`num.clamp` 只有在「接收者与两个参数
    //    全是 double」时才静态推断为 double，否则返回 num 无法赋给 double。
    final double keyboardHeight =
        math.min(mq.size.height * 0.62, 370.0).clamp(300.0, 420.0);

    return Scaffold(
      appBar: AppBar(title: const Text('连接飞牛 NAS')),
      // Back 键：**先关键盘**，键盘已关时交回正常的页面返回逻辑。
      //
      // ⚠️ 关于项目里「全 App 只保留一个 PopScope」的约定：
      //    AppShell 那个 PopScope 与本页**永远不同时在树上** ——
      //    `AppFlow` 在「未登录」时只渲染本页，登录后才换成 AppShell。
      //    因此这里不存在「两个 canPop 相与」的问题。
      body: PopScope(
        canPop: !_keyboardOpen,
        onPopInvokedWithResult: (bool didPop, Object? result) {
          if (!didPop && _keyboardOpen) _closeKeyboard();
        },
        child: Stack(
          children: <Widget>[
            // 见类注释：默认的 DirectionalFocusIntent 会把「焦点在输入框里时的
            // 上下键」静默吞掉，必须在这里显式关掉 ignoreTextFields。
            Shortcuts(
              shortcuts: const <ShortcutActivator, Intent>{
                SingleActivator(LogicalKeyboardKey.arrowDown):
                    DirectionalFocusIntent(
                  TraversalDirection.down,
                  ignoreTextFields: false,
                ),
                SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(
                  TraversalDirection.up,
                  ignoreTextFields: false,
                ),
              },
              // ⚠️ 键盘打开时把整个表单排除出焦点树：
              //    否则方向键会从键盘「漏」到被遮住的输入框上（焦点看不见、用户以为失灵）。
              child: ExcludeFocus(
                excluding: _keyboardOpen,
                child: _buildForm(keyboardHeight),
              ),
            ),
            if (_keyboardOpen)
              Positioned(
                left: 8,
                right: 8,
                bottom: 8,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: keyboardHeight),
                  child: TvKeyboard(
                    controller: _controllerOf(_editing ?? _Field.host),
                    fieldLabel: _labelOf(_editing ?? _Field.host),
                    obscure:
                        (_editing == _Field.pass) && _passObscure,
                    onObscureChanged: (bool v) =>
                        setState(() => _passObscure = v),
                    onClose: _closeKeyboard,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildForm(double keyboardHeight) {
    return Center(
      child: SingleChildScrollView(
        controller: _formScroll,
        // 键盘占用的高度必须补进底部留白，否则「连接并登录」会被键盘压住。
        padding: EdgeInsets.fromLTRB(24, 24, 24, _keyboardOpen ? keyboardHeight + 28 : 24),
        child: SizedBox(
          width: 600,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(kAppName,
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              // 常驻入口：任何时候都能手动唤起遥控器键盘（不依赖计时器）。
              Row(
                children: <Widget>[
                  TvFocus(
                    debugLabel: 'login.kbd.toggle',
                    onPressed: _openKeyboardManually,
                    builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
                      status: s,
                      radius: 10,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(Icons.keyboard, size: 18),
                          SizedBox(width: 8),
                          Text('打开遥控器键盘', style: TextStyle(fontSize: 15)),
                        ],
                      ),
                    ),
                  ),
                  if (_keyboardAuto && _keyboardOpen) ...<Widget>[
                    const SizedBox(width: 10),
                    const Text(
                      '系统键盘未出现，已自动打开遥控器键盘',
                      style: TextStyle(fontSize: 14, color: Color(0xFFFFB4AB)),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 14),
              KeyedSubtree(
                key: _fieldKeys[_Field.host],
                child: TextField(
                  controller: _host,
                  focusNode: _hostFocus,
                  autofocus: true,
                  // ⚠️ 电视端**不设** readOnly：文字输入必须能真正落到 controller。
                  //    键盘由系统 IME 或应用内键盘提供，两者都写同一个 controller。
                  keyboardType: TextInputType.url,
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
              ),
              const SizedBox(height: 16),
              KeyedSubtree(
                key: _fieldKeys[_Field.user],
                child: TextField(
                  controller: _user,
                  focusNode: _userFocus,
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => _passFocus.requestFocus(),
                  decoration: const InputDecoration(
                    labelText: '用户名',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              KeyedSubtree(
                key: _fieldKeys[_Field.pass],
                child: TextField(
                  controller: _pass,
                  focusNode: _passFocus,
                  obscureText: _passObscure,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) {
                    unawaited(_submit());
                  },
                  decoration: const InputDecoration(
                    labelText: '密码',
                    border: OutlineInputBorder(),
                  ),
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
                    style:
                        const TextStyle(fontSize: 15, color: Colors.white54)),
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
              // 输入法可用性（非敏感）：真机排障时唯一能读到的 IME 结论。
              if (_imeInfo != null) ...[
                const SizedBox(height: 6),
                Text(_imeInfo!,
                    style: const TextStyle(
                        fontSize: 13, color: Colors.white38)),
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
    );
  }
}
