import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../core/branding.dart';
import '../../core/exceptions.dart';
import '../../core/log.dart';
import '../../repositories/auth_repository.dart';
import '../../services/text_input_bridge.dart';
import '../widgets/tv_focus.dart';
import '../widgets/tv_keyboard.dart';

/// 登录页（连接飞牛 NAS）。
///
/// ## 遥控器焦点链（**显式**，不依赖框架的空间遍历）
///
/// ```
///      打开遥控器键盘
///            ↓
///      NAS 地址 ⇄ 用户名 ⇄ 密码 ⇄ 记住密码 ⇄ 连接并登录 ⇄ 只测试连接
/// ```
///
/// 反向逐级回去。整条链在 [_LoginPageState._formChain] 里只有**一处**定义，
/// 方向键由页面根 [Focus] 的 `onKeyEvent` 统一分发（见
/// [_LoginPageState._handleRootKey]）。
///
/// ### 为什么不能用「让框架自己找最近的控件」
///
/// 实机故障（海信 E7N Pro 85"）：输完密码后遥控器 **↓ 再也走不出去**，
/// 到不了「记住密码」和「连接并登录」。
///
/// 根因有三层，缺一层都复现：
/// 1. `WidgetsApp` 把方向键绑成 `DirectionalFocusIntent`，其 `ignoreTextFields`
///    默认为 **true** —— 焦点在 `EditableText` 里时方向键被**静默吞掉**；
/// 2. 即使绕开第 1 条，框架用的是**几何最近**启发式：控件在
///    `SingleChildScrollView` 里、部分在视口外时，`rect` 可能无效，
///    遍历会跳过它，落点随滚动位置漂移 —— 表现就是「有时候能进、有时候不能」；
/// 3. 电视端 IME 一旦接管（应用内键盘或系统键盘），方向键先在键盘里循环，
///    走到末行/首行就**原地不动**，用户看到的是「按键没反应」。
///
/// 因此本页三条都治：① 根 `Focus` 显式分发；② 全链显式节点；③ 键盘末行 ↓
/// 与「完成」都等于「我输完了，继续往下」（见 `TvKeyboard.onAdvance`）。
///
/// ## 小米电视 S Pro 2025 不能输入（V6 修复，保留）
///
/// 能选中输入框，但**按 OK 系统软键盘不弹出**。三件事叠加，本页按「层层兜底」：
///
/// 1. 获得焦点后**显式**再调一次 `InputMethodManager.showSoftInput`
///    （见 [TextInputBridge]）；
/// 2. 等待 [imeProbeDelay] 后系统键盘仍未出现（判据 `viewInsets.bottom == 0`）
///    → **自动打开应用内遥控器键盘**；
/// 3. 另有常驻入口「打开遥控器键盘」，任何时候都能手动唤起。
///
/// ## 为什么把「阶段 / 耗时 / 实际地址 / 原始错误」画在屏幕上
///
/// 电视上没有 adb、也拿不到 `boot.log`，此时**屏幕上能读到的东西就是唯一证据**。
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

  // ── 焦点节点 ────────────────────────────────────────────────
  //
  // 全部显式建在 State 里：`onSubmitted` 要靠它们把焦点交给下一个控件；
  // 在 build 里 new 会泄漏，且每次重建都会丢焦点。

  final _hostFocus = FocusNode(debugLabel: 'login.host');
  final _userFocus = FocusNode(debugLabel: 'login.user');
  final _passFocus = FocusNode(debugLabel: 'login.pass');
  final _rememberFocus = FocusNode(debugLabel: 'login.remember');
  final _submitFocus = FocusNode(debugLabel: 'login.submit');
  final _probeFocus = FocusNode(debugLabel: 'login.probe');
  final _kbdToggleFocus = FocusNode(debugLabel: 'login.kbd.toggle');

  /// 页面根节点：**只用来拦截方向键**，自己永不获焦、不参与遍历。
  final _rootFocus = FocusNode(
    debugLabel: 'login.root',
    canRequestFocus: false,
    skipTraversal: true,
  );

  /// 表单主焦点链 —— 方向键顺序的**唯一真相**。
  ///
  /// 顺序 = 视觉顺序。改这里就改整条链，不需要再动任何 `nextXxx`。
  late final List<FocusNode> _formChain = <FocusNode>[
    _kbdToggleFocus,
    _hostFocus,
    _userFocus,
    _passFocus,
    _rememberFocus,
    _submitFocus,
    _probeFocus,
  ];

  /// 节点 → 稳定 id（查滚动锚点用）。
  late final Map<FocusNode, String> _idOf = <FocusNode, String>{
    _kbdToggleFocus: 'kbd',
    _hostFocus: 'host',
    _userFocus: 'user',
    _passFocus: 'pass',
    _rememberFocus: 'remember',
    _submitFocus: 'submit',
    _probeFocus: 'probe',
  };

  /// 每个可聚焦控件的定位锚点（键盘收起后要把目标滚进可见区域）。
  final Map<String, GlobalKey> _anchors = <String, GlobalKey>{
    'kbd': GlobalKey(),
    'host': GlobalKey(),
    'user': GlobalKey(),
    'pass': GlobalKey(),
    'remember': GlobalKey(),
    'submit': GlobalKey(),
    'probe': GlobalKey(),
  };

  /// 表单滚动控制器：键盘弹出时要把正在编辑的字段滚到可见区域。
  final ScrollController _formScroll = ScrollController();

  bool _remember = false;
  bool _busy = false;
  String? _error;

  /// 字段级错误：错在哪个字段 + 给用户看的话。
  ///
  /// 与 [_error] 分工：字段级错误显示在**对应输入框下方**并把焦点送回去，
  /// [_error] 显示在按钮上方，用于「网络不通 / 凭据错误」这类整页性结论。
  _Field? _invalidField;
  String? _invalidMessage;

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

  /// 「刚刚被用户关掉键盘」的字段 —— 该字段**不再自动弹回**，直到焦点换到别的字段。
  ///
  /// ⚠️ 没有这个闸门会出现一个比「输不进字」更难看的 bug：
  /// 用户按「完成」收起键盘后，焦点回到字段 → 焦点监听再次触发 →
  /// 1.2 秒后键盘又自己弹出来，用户会觉得「这键盘关不掉」。
  _Field? _suppressAutoOpenFor;

  /// 用户是否已经**主动操作**过焦点（按过方向键 / 改过输入内容）。
  ///
  /// 用途：地址回填是异步的（读安全存储），若用户已经开始输入或换字段，
  /// 就绝不能再把焦点抢回「按规则算出来的初始位置」。
  bool _userTouchedFocus = false;

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

    // 不等存储读完就先给一个起点：遥控器第一下按键必须有落点。
    //
    // ⚠️ 不能只判 `primaryFocus == null`：上一个页面（启动页）可能刚把焦点
    //    留在某个已卸载的节点上，此时 primaryFocus 非空但不可用。
    //    这里只要「焦点还不在本页的链上」就归位到 host。
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted || _userTouchedFocus) return;
      final FocusNode? cur = FocusManager.instance.primaryFocus;
      if (cur == null || !_idOf.containsKey(cur)) {
        _hostFocus.requestFocus();
      }
    });

    unawaited(_restoreLastHost());
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
    for (final FocusNode n in _formChain) {
      n.dispose();
    }
    _rootFocus.dispose();
    super.dispose();
  }

  // ── 上次地址回填 ───────────────────────────────────────────

  /// 把「最后一次成功登录用过的地址」填回地址框。
  ///
  /// 三条硬约束：
  /// 1. **绝不覆盖用户已经开始输入的内容** —— 用户可能正在改地址，
  ///    异步结果晚到就把人家敲的字冲掉是最不可接受的失败方式；
  /// 2. 读不到 / 读超时都当「没有」处理，不影响登录；
  /// 3. 回填完成后按 [._applyInitialFocus] 的规则决定初始焦点。
  Future<void> _restoreLastHost() async {
    final AuthRepository auth = context.read<AuthRepository>();
    final String? last = await auth.readLastHost();
    if (!mounted) return;

    if (last != null && _host.text.trim().isEmpty && !_userTouchedFocus) {
      _host.text = last;
      Log.i('登录页已回填上次 NAS 地址 ${Log.redactHost(last)}');
    }
    _applyInitialFocus();
  }

  /// 按「缺少哪一项」决定初始焦点（见需求第九条的规则表）。
  void _applyInitialFocus() {
    if (!mounted || _userTouchedFocus) return;
    if (_keyboardOpen) return;
    // 只在焦点还停在默认起点时才调整，避免把用户已经移走的焦点抢回来。
    final FocusNode? cur = FocusManager.instance.primaryFocus;
    if (cur != null && cur != _hostFocus) return;

    _focusAndReveal(_initialFocusNode());
  }

  FocusNode _initialFocusNode() {
    if (_host.text.trim().isEmpty) return _hostFocus;
    if (_user.text.trim().isEmpty) return _userFocus;
    return _passFocus;
  }

  // ── 焦点链 ─────────────────────────────────────────────────

  FocusNode? _nextNodeOf(FocusNode from) {
    final int i = _formChain.indexOf(from);
    if (i < 0 || i + 1 >= _formChain.length) return null;
    return _formChain[i + 1];
  }

  FocusNode? _prevNodeOf(FocusNode from) {
    final int i = _formChain.indexOf(from);
    if (i <= 0) return null;
    return _formChain[i - 1];
  }

  /// 页面根的方向键分发。
  ///
  /// 只处理 ↑ / ↓，且只在「当前焦点确实在链上」时接管 —— 其它情况
  /// （错误详情里的可选文本、滚动区域）一律交回框架，绝不制造新的死区。
  ///
  /// 左右键**不接管**：单行输入框里左右键是移动光标，用户输入 IP 时要用。
  KeyEventResult _handleRootKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;

    final FocusNode? cur = FocusManager.instance.primaryFocus;
    if (cur == null || !_idOf.containsKey(cur)) return KeyEventResult.ignored;

    if (event is KeyRepeatEvent) {
      // 长按不连跳：遥控器长按 ↓ 会连续派发，一下跳过好几格在 3 米外很难控制。
      // 但仍要吞掉 —— 否则框架的几何遍历会中途接管，焦点乱飞。
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    _userTouchedFocus = true;

    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      final FocusNode? next = _nextNodeOf(cur);
      // 链尾：**显式**吞掉，返回 ignored 会让框架的几何遍历接管，
      // 焦点可能被甩到列表外的某个控件上（项目约定：方向到头指回自身）。
      if (next == null) return KeyEventResult.handled;
      _focusAndReveal(next);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      final FocusNode? prev = _prevNodeOf(cur);
      if (prev == null) return KeyEventResult.handled;
      _focusAndReveal(prev);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 聚焦 + 滚进可见区域。
  ///
  /// 滚动的理由不只是「好看」：表单比 540 逻辑高度长得多，在 960×540 档上
  /// 「连接并登录」本来就在视口外 —— 焦点跑过去却看不见，用户会以为没反应。
  void _focusAndReveal(FocusNode node) {
    node.requestFocus();
    final String? id = _idOf[node];
    if (id == null) return;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      _revealById(id);
    });
  }

  void _revealById(String id) {
    final BuildContext? ctx = _anchors[id]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 180),
      alignment: 0.35,
    );
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

  /// 当前焦点落在哪个输入字段上（不在任何字段上则为 null）。
  _Field? _fieldOfFocus() {
    for (final _Field f in _Field.values) {
      if (_focusOf(f).hasFocus) return f;
    }
    return null;
  }

  /// 焦点转移的统一处理：滚动到可见 + 显式唤起系统键盘 + 起「探测」计时器。
  void _onFocusChanged(_Field f) {
    if (!_focusOf(f).hasFocus) {
      _imeProbe?.cancel();
      return;
    }
    _editing = f;
    _revealById(_idOf[_focusOf(f)] ?? 'host');
    // 让输入框的 label / 描边跟着焦点态变化（聚焦色由 `focused` 参数驱动）。
    if (mounted) setState(() {});

    if (_keyboardOpen) return; // 应用内键盘打开时，底层焦点变化不触发新一轮探测
    unawaited(_askSystemKeyboard(f));
    _imeProbe?.cancel();
    // 刚被用户手动关掉键盘的那个字段：不再自动弹回来。
    // 焦点换到**别的**字段时解除抑制（那个字段仍会自动兜底）。
    if (_suppressAutoOpenFor == f) return;
    _suppressAutoOpenFor = null;
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

  /// 打开应用内遥控器键盘（[auto] 表示是「系统键盘没出来」的兜底）。
  void _openKeyboard(_Field f, {bool auto = false}) {
    _imeProbe?.cancel();
    // 系统键盘若也在，先收掉，避免两层键盘叠起来。
    unawaited(TextInputBridge.hideSoftKeyboard());
    setState(() {
      _editing = f;
      _keyboardOpen = true;
      _keyboardAuto = auto;
    });
    _revealById(_idOf[_focusOf(f)] ?? 'host');
  }

  /// 关闭应用内键盘。
  ///
  /// [thenFocus] 为 null = 回到**正在编辑的字段**（Back / 手动关）；
  /// 非 null = 去那个控件（「完成」= 前进、「首行 ↑」= 后退）。
  ///
  /// ⚠️ 顺序不能反：键盘打开时表单被 `ExcludeFocus` 排除，
  /// 此时 `requestFocus` 只会落到最近的可用祖先（表现是「焦点掉到 scope、方向键全失灵」）。
  /// 必须先 setState 解除排除，再在下一帧请求焦点。
  void _closeKeyboard({FocusNode? thenFocus}) {
    final _Field? f = _editing;
    if (!_keyboardOpen) return;
    // 记下「这个字段刚被用户关掉键盘」→ 不再自动弹回（见 [_suppressAutoOpenFor]）。
    _suppressAutoOpenFor = f;
    _imeProbe?.cancel();
    setState(() {
      _keyboardOpen = false;
      _keyboardAuto = false;
    });
    final FocusNode target =
        thenFocus ?? (f == null ? _hostFocus : _focusOf(f));
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      _focusAndReveal(target);
    });
  }

  /// 「完成」= 收起键盘并**前进到下一个控件**。
  ///
  /// 这是本轮 P0 的关键语义：用户输完密码按完成，期望的是
  /// 「键盘没了、焦点到记住密码」，而不是「键盘没了、焦点还赖在密码框」。
  void _advanceFromKeyboard() {
    final _Field current = _editing ?? _Field.host;
    final FocusNode? next = _nextNodeOf(_focusOf(current)) ??
        _nextNodeOf(_hostFocus) ??
        _rememberFocus;
    _closeKeyboard(thenFocus: next);
  }

  /// 「首行 ↑」= 收起键盘并**后退到上一个控件**。
  void _retreatFromKeyboard() {
    final _Field current = _editing ?? _Field.host;
    final FocusNode? prev = _prevNodeOf(_focusOf(current));
    _closeKeyboard(thenFocus: prev ?? _hostFocus);
  }

  /// 系统软键盘的「完成 / 下一项」：结束编辑并前进。
  ///
  /// 这是**系统 IME 路径**上唯一能拿到的信号（IME 可见时方向键会被 IME
  /// 先消费掉，App 收不到 KeyEvent）。因此 `textInputAction` 全部设成
  /// next / done，让 IME 提供「完成」按钮。
  void _advanceFromField(FocusNode from) {
    _userTouchedFocus = true;
    unawaited(TextInputBridge.hideSoftKeyboard());
    final FocusNode? next = _nextNodeOf(from) ?? _rememberFocus;
    _focusAndReveal(next);
  }

  /// 手动入口：为「当前有焦点的字段」打开键盘（没有焦点就取最后编辑的字段）。
  void _openKeyboardManually() {
    final _Field target = _fieldOfFocus() ?? _editing ?? _Field.host;
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

  /// 字段级校验：返回第一个出错的字段与给用户看的话（全部合法则返回 null）。
  ///
  /// 刻意**逐字段**报错而不是「请填写 NAS 地址、用户名与密码」：
  /// 电视上用户看不清是哪一个空了，而且笼统提示无法告诉他该把焦点送回哪。
  ({_Field field, String message})? _validate() {
    final AuthRepository auth = context.read<AuthRepository>();

    final String hostError = auth.hostFormatError(_host.text);
    if (hostError != null) {
      return (field: _Field.host, message: hostError);
    }
    if (_user.text.trim().isEmpty) {
      return (field: _Field.user, message: '请输入用户名');
    }
    if (_pass.text.isEmpty) {
      return (field: _Field.pass, message: '请输入密码');
    }
    return null;
  }

  /// 把「字段 → 节点」映射成公开的错误定位。
  void _showFieldError(_Field field, String message) {
    setState(() {
      _invalidField = field;
      _invalidMessage = message;
      _error = null;
      _detail = null;
      _notice = null;
    });
    _focusAndReveal(_focusOf(field));
  }

  /// 把技术性错误翻译成用户能执行的一句话。
  String _friendlyError(AppError e) {
    switch (e.kind) {
      case ErrorKind.auth:
        return '用户名或密码错误';
      case ErrorKind.network:
        return '无法连接到 NAS，请检查 NAS 地址或网络';
      case ErrorKind.parse:
      case ErrorKind.server:
      case ErrorKind.notFound:
      case ErrorKind.tokenExpired:
      case ErrorKind.unknown:
        return e.message;
    }
  }

  Future<void> _submit() async {
    if (_busy) return;

    final ({_Field field, String message})? invalid = _validate();
    if (invalid != null) {
      _showFieldError(invalid.field, invalid.message);
      return;
    }

    final host = _host.text.trim();
    final username = _user.text.trim();
    final password = _pass.text;

    // context 相关的东西必须在 await 之前取完（use_build_context_synchronously）。
    final auth = context.read<AuthRepository>();
    setState(() {
      _busy = true;
      _error = null;
      _detail = null;
      _notice = null;
      _invalidField = null;
      _invalidMessage = null;
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
      final AppError err = res.error;
      setState(() {
        _busy = false;
        _stage = null;
        _error = _friendlyError(err);
        _detail = 'kind=${err.kind.name}'
            '${err.cause == null ? '' : '\n${err.cause}'}';
      });
      // 凭据错误：把焦点送回密码框并全选，用户可以直接重打。
      if (err.kind == ErrorKind.auth) {
        _pass.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _pass.text.length,
        );
        _focusAndReveal(_passFocus);
      }
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
    if (_busy) return;
    final AuthRepository auth = context.read<AuthRepository>();
    final String hostError = auth.hostFormatError(_host.text);
    if (hostError != null) {
      _showFieldError(_Field.host, hostError);
      return;
    }
    final host = _host.text.trim();
    setState(() {
      _busy = true;
      _error = null;
      _detail = null;
      _notice = null;
      _invalidField = null;
      _invalidMessage = null;
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
        _error = _friendlyError(res.error);
        _detail = 'kind=${res.error.kind.name}'
            '${res.error.cause == null ? '' : '\n${res.error.cause}'}';
      } else {
        _notice = res.value;
      }
    });
  }

  void _toggleRemember() {
    setState(() => _remember = !_remember);
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
            // ⚠️ 层次不能错：`Shortcuts` 必须是最外层，根 `Focus` 在它**里面**，
            //    这样方向键冒泡时会先到我们的 `_handleRootKey`，再到 `Shortcuts`
            //    的 `DirectionalFocusIntent`。反过来的话框架会先接管（几何遍历），
            //    我们的显式链就永远轮不到。
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
              child: Focus(
                focusNode: _rootFocus,
                canRequestFocus: false,
                skipTraversal: true,
                onKeyEvent: _handleRootKey,
                // ⚠️ 键盘打开时把整个表单排除出焦点树：
                //    否则方向键会从键盘「漏」到被遮住的输入框上（焦点看不见、用户以为失灵）。
                child: ExcludeFocus(
                  excluding: _keyboardOpen,
                  child: _buildForm(keyboardHeight),
                ),
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
                    obscure: (_editing == _Field.pass) && _passObscure,
                    onObscureChanged: (bool v) =>
                        setState(() => _passObscure = v),
                    onClose: _closeKeyboard,
                    // 末行 ↓ / 「完成」→ 收起键盘并前进到下一个控件。
                    onAdvance: _advanceFromKeyboard,
                    // 首行 ↑ → 收起键盘并回到上一个控件。
                    onRetreat: _retreatFromKeyboard,
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
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          _keyboardOpen ? keyboardHeight + 28 : 24,
        ),
        child: SizedBox(
          width: 600,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                kAppName,
                style: TextStyle(
                  fontSize: 26,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: TvSpacing.sm),
              // 常驻入口：任何时候都能手动唤起遥控器键盘（不依赖计时器）。
              Row(
                children: <Widget>[
                  KeyedSubtree(
                    key: _anchors['kbd'],
                    child: TvFocus(
                      focusNode: _kbdToggleFocus,
                      debugLabel: 'login.kbd.toggle',
                      onPressed: _openKeyboardManually,
                      // 上下键交给页面根 `_handleRootKey` 统一分发
                      // （`_formChain` 是唯一真相）；左右指回自身，防止框架
                      // 用几何遍历把焦点甩到别处。
                      nextLeft: _kbdToggleFocus,
                      nextRight: _kbdToggleFocus,
                      builder: (BuildContext context, TvFocusStatus s) =>
                          TvFocusRing(
                        status: s,
                        radius: TvRadii.tile,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(Icons.keyboard, size: 18),
                            SizedBox(width: 8),
                            Text(
                              '打开遥控器键盘',
                              style: TextStyle(fontSize: 15, height: 1.2),
                            ),
                          ],
                        ),
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
              const SizedBox(height: TvSpacing.md),
              _buildTextField(
                field: _Field.host,
                controller: _host,
                focusNode: _hostFocus,
                label: 'NAS 地址（含端口）',
                hint: 'http://192.168.3.250:5666',
                helper: '漏写 http:// 也没关系，会自动补上',
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: TvSpacing.md),
              _buildTextField(
                field: _Field.user,
                controller: _user,
                focusNode: _userFocus,
                label: '用户名',
                keyboardType: TextInputType.text,
              ),
              const SizedBox(height: TvSpacing.md),
              _buildTextField(
                field: _Field.pass,
                controller: _pass,
                focusNode: _passFocus,
                label: '密码',
                keyboardType: TextInputType.visiblePassword,
                obscure: _passObscure,
              ),
              const SizedBox(height: TvSpacing.sm),
              KeyedSubtree(
                key: _anchors['remember'],
                child: _buildRememberRow(),
              ),
              if (_stage != null) ...[
                const SizedBox(height: 4),
                Text(
                  '$_stage 已等待 $_elapsed 秒',
                  style: const TextStyle(
                    fontSize: 17,
                    height: 1.3,
                    color: Color(0xFF8AB4F8),
                  ),
                ),
              ],
              if (_target != null && _target!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  '实际请求地址：$_target',
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.3,
                    color: TvColors.textFaint,
                  ),
                ),
              ],
              if (_notice != null) ...[
                const SizedBox(height: 8),
                Text(
                  _notice!,
                  style: const TextStyle(
                    fontSize: 18,
                    height: 1.3,
                    color: TvColors.ok,
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: const TextStyle(
                    fontSize: 19,
                    height: 1.3,
                    color: Color(0xFFFF8A80),
                  ),
                ),
              ],
              if (_detail != null) ...[
                const SizedBox(height: 6),
                // 原始错误：电视上没有 adb，这一块是唯一能带回来的证据。
                // ⚠️ 刻意用普通 `Text` 而不是 `SelectableText`：
                //    后者会创建一个**可获焦**的节点，方向键会掉进去出不来
                //    （电视上没有复制需求，这个可聚焦性纯属负担）。
                Text(
                  _detail!,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    fontFamily: 'monospace',
                    color: Color(0xFFFFB4AB),
                  ),
                ),
              ],
              // 输入法可用性（非敏感）：真机排障时唯一能读到的 IME 结论。
              if (_imeInfo != null) ...[
                const SizedBox(height: 6),
                Text(
                  _imeInfo!,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.3,
                    color: TvColors.textFaint,
                  ),
                ),
              ],
              const SizedBox(height: TvSpacing.lg),
              KeyedSubtree(
                key: _anchors['submit'],
                child: _buildSubmitButton(),
              ),
              const SizedBox(height: TvSpacing.sm),
              KeyedSubtree(
                key: _anchors['probe'],
                child: _buildProbeButton(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 一个输入框（含焦点描边、字段级错误、键盘「完成/下一项」处理）。
  Widget _buildTextField({
    required _Field field,
    required TextEditingController controller,
    required FocusNode focusNode,
    required String label,
    String? hint,
    String? helper,
    TextInputType? keyboardType,
    bool obscure = false,
  }) {
    final bool focused = focusNode.hasFocus;
    final bool hasError = _invalidField == field;
    final Color borderColor = hasError
        ? const Color(0xFFFF8A80)
        : (focused ? TvColors.focusRing : TvColors.line);

    return KeyedSubtree(
      key: _anchors[_idOf[focusNode]],
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        // ⚠️ 电视端**不设** readOnly：文字输入必须能真正落到 controller。
        //    键盘由系统 IME 或应用内键盘提供，两者都写同一个 controller。
        keyboardType: keyboardType,
        obscureText: obscure,
        // 全部用 next/done：让 IME 提供一个明确的「下一项 / 完成」按钮。
        // 这是系统 IME 路径上唯一能收到的信号（IME 可见时方向键归 IME）。
        textInputAction: TextInputAction.next,
        onChanged: (_) {
          _userTouchedFocus = true;
          // 用户开始修正就撤掉字段级错误提示（否则红色边框会一直挂着，
          // 看起来像「我改了还是错」）。
          if (_invalidField != null) {
            setState(() {
              _invalidField = null;
              _invalidMessage = null;
            });
          }
        },
        onSubmitted: (_) => _advanceFromField(focusNode),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: helper,
          errorText: hasError ? _invalidMessage : null,
          labelStyle: TextStyle(
            fontSize: 16,
            color: focused ? TvColors.focusRing : TvColors.textDim,
          ),
          floatingLabelStyle: TextStyle(
            fontSize: 16,
            color: focused ? TvColors.focusRing : TvColors.textDim,
          ),
          hintStyle: const TextStyle(fontSize: 16, color: TvColors.textFaint),
          helperStyle: const TextStyle(
            fontSize: 13,
            color: TvColors.textFaint,
          ),
          errorStyle: const TextStyle(
            fontSize: 14,
            color: Color(0xFFFF8A80),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(TvRadii.tile),
            borderSide: BorderSide(color: borderColor, width: 1),
          ),
          // 聚焦描边用焦点环色 + 2.5px：与 TvFocusRing 同一套视觉语言，
          // 用户不需要区分「这是输入框的焦点」还是「这是按钮的焦点」。
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(TvRadii.tile),
            borderSide: BorderSide(color: borderColor, width: 2.5),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(TvRadii.tile),
            borderSide: const BorderSide(color: Color(0xFFFF8A80), width: 1.5),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(TvRadii.tile),
            borderSide: const BorderSide(color: Color(0xFFFF8A80), width: 2.5),
          ),
        ),
      ),
    );
  }

  /// 「记住密码」—— 用自己的 TvFocus + 自绘勾选框。
  ///
  /// ⚠️ 不用 `CheckboxListTile`：它内部自带 `FocusNode`/`InkWell`，
  ///    与项目「一个控件只允许一个焦点节点」的铁律冲突，而且**没有焦点环** ——
  ///    电视上用户看不到焦点停在这里，会以为 ↓ 没生效。
  Widget _buildRememberRow() {
    return TvFocus(
      focusNode: _rememberFocus,
      debugLabel: 'login.remember',
      onPressed: _toggleRemember,
      nextLeft: _rememberFocus,
      nextRight: _rememberFocus,
      builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
        status: s,
        radius: TvRadii.tile,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        child: Row(
          children: <Widget>[
            _TvCheckBox(value: _remember, focused: s.focused),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                '记住密码并自动重新登录（仅保存 sha256 哈希）',
                maxLines: 2,
                style: TextStyle(
                  fontSize: 16,
                  height: 1.35,
                  color: TvColors.textDim,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubmitButton() {
    // ⚠️ 按钮**始终可获焦**：即使字段为空也不灰掉。
    //    电视端「灰掉的按钮」意味着遥控器按上去没有任何反馈，
    //    用户会以为遥控器坏了；正确做法是让他按下去、然后告诉他缺什么。
    return TvFocus(
      focusNode: _submitFocus,
      debugLabel: 'login.submit',
      onPressed: _submit,
      nextLeft: _submitFocus,
      nextRight: _submitFocus,
      builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
        status: s,
        radius: TvRadii.tile,
        padding: EdgeInsets.zero,
        height: 52,
        baseColor: TvColors.accent,
        focusColor: TvColors.pressedFill,
        pressedColor: TvColors.pressedFill,
        strongHalo: true,
        child: Center(
          child: Text(
            _busy ? '连接中…' : '连接并登录',
            style: const TextStyle(
              fontSize: 20,
              height: 1.2,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProbeButton() {
    return TvFocus(
      focusNode: _probeFocus,
      debugLabel: 'login.probe',
      onPressed: _probe,
      nextLeft: _probeFocus,
      nextRight: _probeFocus,
      builder: (BuildContext context, TvFocusStatus s) => TvFocusRing(
        status: s,
        radius: TvRadii.tile,
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: const Center(
          child: Text(
            '只测试连接（不需账号和密码）',
            style: TextStyle(
              fontSize: 17,
              height: 1.2,
              color: TvColors.textDim,
            ),
          ),
        ),
      ),
    );
  }
}

/// 自绘勾选框（只用 `Icon` + `Container`，不引入任何 Material 焦点控件）。
class _TvCheckBox extends StatelessWidget {
  const _TvCheckBox({required this.value, required this.focused});

  final bool value;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final Color borderColor = value
        ? TvColors.accent
        : (focused ? TvColors.focusRing : TvColors.line);
    return AnimatedContainer(
      duration: TvMotion.focus,
      curve: Curves.easeOut,
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: value ? TvColors.accent : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: borderColor, width: 2),
      ),
      child: value
          ? const Icon(Icons.check, size: 15, color: Colors.white)
          : null,
    );
  }
}
