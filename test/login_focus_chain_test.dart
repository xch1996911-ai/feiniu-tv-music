import 'package:feiniu_tv_music/app/theme.dart';
import 'package:feiniu_tv_music/repositories/auth_repository.dart';
import 'package:feiniu_tv_music/ui/pages/login_page.dart';
import 'package:feiniu_tv_music/ui/widgets/tv_keyboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_secure_store.dart';

/// 登录页遥控器焦点链回归（UI2.0-DEV2）。
///
/// ## 实机故障（海信 E7N Pro 85"）
///
/// 输入完密码后遥控器 **↓ 再也走不出去**，到不了「记住密码」和「连接并登录」，
/// 于是登录动作完全无法完成。同时地址框为空（每次都要用遥控器手打 IP:端口）。
///
/// ## 本文件守的四条线
/// 1. **显式焦点链**：↑/↓ 只能按 `_formChain` 的顺序走，不允许框架用几何最近
///    启发式「大概找到哪算哪」；
/// 2. **键盘不是监狱**：应用内键盘末行 ↓ / 「完成」必须收起键盘并前进；
/// 3. **字段级校验**：空/格式错分别给不同文案，并把焦点送回出错字段；
/// 4. **地址回填**：登录过一次以后，登录页自动带上地址，并按缺哪项决定初始焦点。
void main() {
  String? focusedLabel() => FocusManager.instance.primaryFocus?.debugLabel;

  /// 地址框里**真正的内容**。
  ///
  /// ⚠️ 不用 `find.text(...)` 断言：`TextField` 的 hint / EditableText
  ///    可能让同一段文字命中多个 widget（hint 曾经恰好等于回填值，
  ///    直接导致 findsOneWidget 变 findsNWidgets(2)）。
  String hostText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField).first).controller!.text;

  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, [
    int times = 1,
  ]) async {
    for (int i = 0; i < times; i++) {
      await tester.sendKeyEvent(key);
      await tester.pump();
    }
  }

  Future<void> pumpLogin(
    WidgetTester tester, {
    String? lastHost,
    Size physical = const Size(1920, 1080),
    double dpr = 1.0,
  }) async {
    tester.view.physicalSize = physical;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);

    final store = FakeSecureStore();
    if (lastHost != null) store.prefs['lastHost'] = lastHost;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthRepository>.value(
            value: AuthRepository(store: store),
          ),
        ],
        child: MaterialApp(
          theme: buildTvTheme(),
          home: LoginPage(onLoggedIn: () {}),
        ),
      ),
    );
    // postFrame（初始焦点）+ 异步读取「上次地址」各需要一帧。
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Future<void> tearDownTree(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  /// 推进到「系统键盘没出来 → 自动打开应用内键盘」。
  Future<void> waitForFallback(WidgetTester tester) async {
    await tester.pump(
      LoginPage.imeProbeDelay + const Duration(milliseconds: 50),
    );
    await tester.pump();
    await tester.pump();
  }

  // ── 一、焦点链 ──────────────────────────────────────────────

  group('显式焦点链（↑/↓ 只走 _formChain）', () {
    testWidgets('↓ 依次走 地址 → 用户名 → 密码 → 记住密码 → 连接并登录 → 只测试连接',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpLogin(tester);
      expect(focusedLabel(), 'login.host', reason: '地址为空时初始焦点必须是地址框');

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'login.user');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'login.pass',
          reason: '这一格是实机 bug 的现场：从这里 ↓ 原来出不去');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'login.remember');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'login.submit');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'login.probe');

      // 到底了：不移动（交给框架也没别的地方可去，但绝不能乱跳）
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'login.probe', reason: '链尾按 ↓ 必须原地不动');

      await tearDownTree(tester);
    });

    testWidgets('↑ 原路返回，从地址框再 ↑ 到「打开遥控器键盘」',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpLogin(tester);

      // host 到 submit 是 4 格：user → pass → remember → submit
      await press(tester, LogicalKeyboardKey.arrowDown, 4);
      expect(focusedLabel(), 'login.submit');

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), 'login.remember');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), 'login.pass');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), 'login.user');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), 'login.host');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), 'login.kbd.toggle');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), 'login.kbd.toggle', reason: '链首按 ↑ 必须原地不动');

      await tearDownTree(tester);
    });

    testWidgets('左右键在按钮上不越界（不会被几何遍历甩到别的控件）',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpLogin(tester);
      await press(tester, LogicalKeyboardKey.arrowDown, 4);
      expect(focusedLabel(), 'login.submit');

      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(focusedLabel(), 'login.submit');
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedLabel(), 'login.submit');

      await tearDownTree(tester);
    });

    testWidgets('960×540 小视口下焦点链照样能走到底（且不溢出）',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpLogin(tester, physical: const Size(960, 540));
      expect(tester.takeException(), isNull);

      await press(tester, LogicalKeyboardKey.arrowDown, 6);
      expect(focusedLabel(), 'login.probe',
          reason: '小视口下控件在视口外也必须能走到 —— 焦点与滚动解耦');
      expect(tester.takeException(), isNull);

      await tearDownTree(tester);
    });
  });

  // ── 二、应用内键盘的出口 ────────────────────────────────────

  group('应用内键盘不是监狱（末行 ↓ / 完成都能出去）', () {
    testWidgets('末行按 ↓ → 收起键盘并前进到下一个控件',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpLogin(tester);
      await waitForFallback(tester);
      expect(find.byType(TvKeyboard), findsOneWidget);

      // 一路 ↓ 到末行（空格键）
      await press(tester, LogicalKeyboardKey.arrowDown, 5);
      expect(focusedLabel(), 'tvkbd.space');

      // 末行 ↓ = 「我输完了，继续往下」
      await press(tester, LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.pump();

      expect(find.byType(TvKeyboard), findsNothing,
          reason: '末行 ↓ 必须能关掉键盘，这是实机「下不去」的正面解法');
      expect(focusedLabel(), 'login.user');

      await tearDownTree(tester);
    });

    testWidgets('首行按 ↑ → 收起键盘并回到上一个控件',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpLogin(tester);
      // 先把焦点挪到用户名，让它那一栏打开键盘
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedLabel(), 'login.user');
      await waitForFallback(tester);
      expect(find.byType(TvKeyboard), findsOneWidget);
      expect(find.text('正在编辑：用户名'), findsOneWidget);

      await press(tester, LogicalKeyboardKey.arrowUp);
      await tester.pump();
      await tester.pump();

      expect(find.byType(TvKeyboard), findsNothing);
      expect(focusedLabel(), 'login.host',
          reason: '首行 ↑ = 退出键盘往上走，不能原地死循环');

      await tearDownTree(tester);
    });

    testWidgets('密码框用键盘输完 → 完成 → 落在「记住密码」（本轮的原始诉求）',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpLogin(tester);
      await press(tester, LogicalKeyboardKey.arrowDown, 2); // → 密码
      expect(focusedLabel(), 'login.pass');

      await waitForFallback(tester);
      expect(find.byType(TvKeyboard), findsOneWidget);
      expect(find.text('正在编辑：密码'), findsOneWidget);

      // 输一位密码
      await press(tester, LogicalKeyboardKey.enter);
      // 走到底点「完成」
      await press(tester, LogicalKeyboardKey.arrowDown, 5);
      await press(tester, LogicalKeyboardKey.arrowRight, 3);
      expect(focusedLabel(), 'tvkbd.done');
      await press(tester, LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();

      expect(find.byType(TvKeyboard), findsNothing);
      expect(focusedLabel(), 'login.remember',
          reason: '密码输完 → 记住密码 → 再 ↓ 就是「连接并登录」，全程只用遥控器');

      await tearDownTree(tester);
    });
  });

  // ── 三、字段级校验 ──────────────────────────────────────────

  group('字段级校验（不许再出现笼统的「请填写…」）', () {
    /// 从**任意位置**回到「连接并登录」。
    ///
    /// 先一路 ↑ 到链首（「打开遥控器键盘」，多按几下会停在链首），
    /// 再数 5 格下去 —— 这样不依赖当前初始焦点落在哪一栏
    /// （地址被回填时初始焦点会直接落在用户名上）。
    Future<void> focusSubmit(WidgetTester tester) async {
      await press(tester, LogicalKeyboardKey.arrowUp, 8);
      await press(tester, LogicalKeyboardKey.arrowDown, 5);
      expect(focusedLabel(), 'login.submit');
      await press(tester, LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('地址为空 → 「请输入 NAS 地址」+ 焦点回地址框',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpLogin(tester);
      await focusSubmit(tester);

      expect(find.text('请输入 NAS 地址'), findsOneWidget);
      expect(focusedLabel(), 'login.host',
          reason: '报错后必须把焦点送回出错字段，用户在遥控器上不用自己找回去');

      await tearDownTree(tester);
    });

    testWidgets('地址格式错 → 明确提示 + 焦点回地址框',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpLogin(tester);
      await tester.enterText(
        find.byType(TextField).first,
        'not-a-host',
      );
      await tester.pump();
      await focusSubmit(tester);

      expect(
        find.text('NAS 地址格式不正确，例如 http://192.168.3.250:5666'),
        findsOneWidget,
      );
      expect(focusedLabel(), 'login.host');

      await tearDownTree(tester);
    });

    testWidgets('用户名为空 → 「请输入用户名」+ 焦点回用户名框',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpLogin(tester, lastHost: 'http://192.168.3.250:5666');
      await focusSubmit(tester);

      expect(find.text('请输入用户名'), findsOneWidget);
      expect(focusedLabel(), 'login.user');

      await tearDownTree(tester);
    });

    testWidgets('密码为空 → 「请输入密码」+ 焦点回密码框',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpLogin(tester, lastHost: 'http://192.168.3.250:5666');
      await tester.enterText(find.byType(TextField).at(1), 'admin');
      await tester.pump();
      await focusSubmit(tester);

      expect(find.text('请输入密码'), findsOneWidget);
      expect(focusedLabel(), 'login.pass');

      await tearDownTree(tester);
    });

    testWidgets('开始打字后字段级错误自动消失',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpLogin(tester);
      await focusSubmit(tester);
      expect(find.text('请输入 NAS 地址'), findsOneWidget);

      // 焦点已经被送回地址框，直接输入
      await tester.enterText(find.byType(TextField).first, '192.168.3.250:5666');
      await tester.pump();
      expect(find.text('请输入 NAS 地址'), findsNothing,
          reason: '用户已经在改了，红色提示还挂着会让人以为「改了还是错」');

      await tearDownTree(tester);
    });
  });

  // ── 四、「记住密码」与「连接并登录」的 OK 行为 ──────────────

  group('OK 键必须真的有动作', () {
    testWidgets('「记住密码」按 OK 勾选 / 取消（有可见的勾）',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpLogin(tester);
      await press(tester, LogicalKeyboardKey.arrowDown, 3);
      expect(focusedLabel(), 'login.remember');

      expect(find.byIcon(Icons.check), findsNothing, reason: '默认不勾');
      await press(tester, LogicalKeyboardKey.enter);
      expect(find.byIcon(Icons.check), findsOneWidget, reason: '按 OK 必须勾上');
      await press(tester, LogicalKeyboardKey.enter);
      expect(find.byIcon(Icons.check), findsNothing, reason: '再按一次取消');

      await tearDownTree(tester);
    });

    testWidgets('「连接并登录」字段为空时**仍然可获焦**（不是灰掉的死控件）',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpLogin(tester);
      await press(tester, LogicalKeyboardKey.arrowDown, 4);
      expect(focusedLabel(), 'login.submit',
          reason: '字段为空也不许把按钮变成遥控器够不到的 Disabled 控件');

      // 按下去要有明确结论（而不是「有视觉反馈但什么都不发生」）
      await press(tester, LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.text('请输入 NAS 地址'), findsOneWidget);

      await tearDownTree(tester);
    });
  });

  // ── 五、地址恢复与初始焦点 ──────────────────────────────────

  group('NAS 地址恢复（登录过一次就不该再手打）', () {
    testWidgets('有上次成功地址 → 自动回填，且初始焦点直接落在用户名',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpLogin(tester, lastHost: 'http://192.168.3.250:5666');

      expect(hostText(tester), 'http://192.168.3.250:5666',
          reason: '地址不是密码，可以明文保存；电视遥控器打 IP 太痛苦');
      expect(focusedLabel(), 'login.user',
          reason: '地址已就绪 → 初始焦点应跳过地址框');

      await tearDownTree(tester);
    });

    testWidgets('从未成功登录过 → 地址为空，初始焦点在地址框',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpLogin(tester);
      expect(hostText(tester), isEmpty);
      expect(focusedLabel(), 'login.host');

      await tearDownTree(tester);
    });

    testWidgets('回填不会覆盖用户已经开始输入的地址',
        timeout: const Timeout(Duration(seconds: 45)),
        (WidgetTester tester) async {
      await pumpLogin(tester, lastHost: 'http://192.168.3.250:5666');
      // 用户改成了另一台 NAS
      await tester.enterText(find.byType(TextField).first, '10.0.0.9:5666');
      await tester.pump();
      await tester.pump(LoginPage.imeProbeDelay);

      expect(hostText(tester), '10.0.0.9:5666',
          reason: '用户输入的值必须留得住（回填只允许发生在「地址框还空着」时）');

      await tearDownTree(tester);
    });
  });

  // ── 六、地址校验（纯逻辑）──────────────────────────────────

  group('NAS 地址校验（AuthRepository.hostFormatError）', () {
    final auth = AuthRepository(store: FakeSecureStore());

    test('空 / 全空白 → 「请输入 NAS 地址」', () {
      expect(auth.hostFormatError(''), '请输入 NAS 地址');
      expect(auth.hostFormatError('    '), '请输入 NAS 地址');
    });

    test('合法写法全部放行', () {
      expect(auth.hostFormatError('192.168.3.250:5666'), isNull,
          reason: '漏写 http:// 是电视上最常见的情况，会自动补');
      expect(auth.hostFormatError('http://192.168.3.250:5666'), isNull);
      expect(auth.hostFormatError('https://nas.example.com'), isNull);
      expect(auth.hostFormatError('localhost:5666'), isNull);
      expect(auth.hostFormatError('my-nas.lan'), isNull);
    });

    test('明显打错 → 给出可照抄的示例', () {
      for (final String bad in <String>[
        'not-a-host',
        'http://',
      ]) {
        expect(
          auth.hostFormatError(bad),
          'NAS 地址格式不正确，例如 http://192.168.3.250:5666',
          reason: '输入 $bad 应被判格式错误',
        );
      }
    });
  });
}
