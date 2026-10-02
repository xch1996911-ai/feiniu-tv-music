# Android TV 黑屏 / 闪退问题：根因、取证与诊断约定

> 现象演进：
> - **第一轮**：APK 在电视上安装成功，点开**纯黑屏，什么都不显示**，无报错、无界面。
> - **第二轮**（修复第一轮之后）：变成**黑屏然后闪退**，进程直接消失。
>
> 本文按时间顺序记录两轮的根因、修复方案，以及后续排错必须遵守的
> 「颜色即信号」+「日志落盘」两条约定。

---

# 第一轮：纯黑屏（不闪退）

## 一、根因

### 1.1 主因：`runApp` 之前 await 了不可靠的初始化

修复前的 `lib/main.dart`：

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final handler = await MediaSessionService.init(); // ① audio_service 起前台服务
  final auth = AuthRepository();
  await auth.restore();                             // ② flutter_secure_storage / Keystore

  final music = MusicRepository(auth);
  final playback = PlaybackRepository(music: music, handler: handler);

  runApp(App(auth: auth, music: music, playback: playback));
}
```

这两步在 Android TV 上**都不可靠**：

| 步骤 | 失败方式 | 触发条件 |
|---|---|---|
| ① `MediaSessionService.init()` | 抛异常 **或永久挂起** | 厂商 ROM 拒绝前台服务；服务绑定一直不回调 |
| ② `auth.restore()` | 抛异常 | 盒子/电视的 Android Keystore 不可用，`EncryptedSharedPreferences` 读写失败 |

任一种情况发生，`runApp` 就**永远不执行**。注意：Dart 顶层未捕获异常**不会杀死进程**，
只会让后续代码不执行 —— 所以表现为「黑屏但**不闪退**、也没有任何界面」。

### 1.2 为什么是「纯黑」而不是别的

```xml
<!-- android/app/src/main/res/drawable/launch_background.xml（修复前） -->
<item android:drawable="@android:color/black" />
```

启动窗口背景是**纯黑**。Flutter 首帧永远不来，屏幕就一直停在启动窗口上，
于是看起来就是「黑屏，什么都没有」——而且电视上通常没有 adb，连 logcat 都拿不到。

### 1.3 次因：Android 14+ 前台服务权限缺失

`AndroidManifest.xml` 里 `targetSdk = 36`、service 声明了
`android:foregroundServiceType="mediaPlayback"`，但**只申请了
`FOREGROUND_SERVICE`，漏了 `FOREGROUND_SERVICE_MEDIA_PLAYBACK`**。
API 34 起这是硬性要求，缺了会在 `startForeground()` 抛 `SecurityException`，
直接命中上面的失败路径 ①。

## 二、第一轮修复

| 文件 | 改动 |
|---|---|
| `lib/main.dart` | **`runApp` 之前不再有任何 `await`**；同步 `runApp(const BootApp())`；`runZonedGuarded` + `FlutterError.onError` 兜底 |
| `lib/boot/boot_screen.dart`（新增） | 启动引导页：三步初始化逐步 `try/catch` **+ 超时**，可降级；失败原因**画在屏幕上** |
| `lib/app/theme.dart`（新增） | 引导页与主界面共用主题，避免切换时样式跳变 |
| `lib/app/app.dart` | 改用共享主题；修掉 `dispose()` 里 `context.read` 的不安全用法 |
| `lib/playback/media_session_service.dart` | `init()` 内置 15s 超时（防「永久挂起」） |
| `lib/services/secure_store.dart` | 加密存储失败自动降级为普通存储并重试一次 |
| `android/.../AndroidManifest.xml` | 补 `FOREGROUND_SERVICE_MEDIA_PLAYBACK` |
| `android/.../res/drawable/launch_background.xml` | 纯黑 → 深蓝（见第五节） |

---

# 第二轮：黑屏 → 闪退

## 三、为什么「修完反而崩了」

第一轮的修复方向是对的，但它**把一个隐藏问题从「不执行」变成了「执行」**：

```text
第一轮：await MediaSessionService.init()  ← 这里就抛异常/挂起了
        ⇒ 后面的 init / restore 全都没跑，runApp 也没跑
        ⇒ 现象：纯黑，不闪退

第二轮：runApp 同步执行，屏幕终于画出来了
        ⇒ 那些初始化开始**真的跑到原生层**（前台服务、Keystore）
        ⇒ 其中一步在 native 层崩溃（SIGSEGV / SIGABRT）
        ⇒ 现象：黑屏 → 闪退
```

关键点：**native crash（原生崩溃）不是 Dart 异常，`try/catch` 拦不住。**
所以第一轮加的降级逻辑根本没机会生效，进程就没了。

同时还有一个「伪修复」被清掉：

```xml
<!-- 第一轮加的，无效 -->
<meta-data android:name="io.flutter.embedding.android.EnableImpeller"
           android:value="false" />
```

Flutter 的渲染后端演进（上游）：

| 版本 | Android 侧状态 |
|---|---|
| 3.27 | API 29+ 默认 Impeller |
| 3.38 | 手动 opt-out 被 **deprecate**（用会打运行时警告） |
| 3.41 / 3.44 | **Android 10+ 的 Skia 后端被移除**，Impeller 是唯一路径 |

本项目用 **Flutter 3.47.6**，所以「关掉 Impeller 回退 Skia」既无效、又让
黑屏的归因变得模糊 —— 已删除。

## 四、第二轮修复

### 4.1 崩溃日志落盘（最重要）

电视上没有 adb ⇒ 唯一可行的取证方式是**让 App 自己把日志写进文件**。

| 位置 | 内容 |
|---|---|
| `MainActivity.installCrashHandler()` | 在 `super.onCreate` **之前**装 `Thread.setDefaultUncaughtExceptionHandler`，任何未捕获的原生异常（含 Flutter 引擎启动阶段的崩溃）连同完整堆栈写入日志文件 |
| `MainActivity.note()` | 记录原生关键节点：`MainActivity.onCreate 开始` / `super.onCreate 返回` / `MethodChannel 已注册` |
| `lib/core/boot_log.dart`（新增） | Dart 侧每个启动节点写 `[dart] xxx`，**同一个文件** |

日志文件路径：

```
/storage/emulated/0/Android/data/com.feiniu.tv.music/files/bootlog/boot.log
```

**判定规则（见下节）**。

### 4.2 自动安全模式

原生在 `onCreate` 里把 `boot_attempts` 加一并持久化；Dart 侧启动全部走完后
调用 `markBootOk` 清零。于是：

| `boot_attempts` | 含义 | 本次行为 |
|---|---|---|
| 1 | 第一次启动 | 正常模式（会调用 audio_service / 安全存储） |
| **≥ 2** | **上次启动没走完**（大概率崩在原生层） | **安全模式**：跳过 audio_service 与安全存储读取，直接用裸 `PlaybackHandler`，优先保证「能看到界面」 |

也就是说：即使第一轮仍会崩一次，**第二次打开就会自动绕过崩溃步骤**，
用户至少能进到登录页把 UI / 网络 / 登录链路验完。

### 4.3 deviceId 不再走 Keystore

`deviceId` 只是随机标识、**非机密**，但原先存在 `flutter_secure_storage`
（`EncryptedSharedPreferences` → Android Keystore）。部分电视 ROM 上
Keystore 不可用会让这一读写**在原生层直接崩溃**。

现在改由原生 `SharedPreferences` 管理（`MainActivity.deviceId()`：
`SecureRandom` 16 字节 → 32 位小写 hex → 持久化），Dart 侧通过
`BootLog.nativeDeviceId()` 读取。`flutter_secure_storage` 仍保留用于
token 会话，但**读会话失败只会降级，不会崩**。

### 4.4 渲染后端改钉 OpenGL ES

```xml
<meta-data android:name="io.flutter.embedding.android.ImpellerBackend"
           android:value="opengles" />
```

不再试图关闭 Impeller（已无 Skia 可退），而是把 Impeller 后端固定在
**OpenGL ES**，绕开部分电视盒子有缺陷的 Vulkan 驱动
（典型症状正是「进程活着、画面全黑」）。

### 4.5 其余

| 文件 | 改动 |
|---|---|
| `lib/boot/boot_screen.dart` | 步骤之间加短延迟，让引导页先画出来；每步前后写日志；新增诊断块（系统版本 / 启动次数 / 日志路径 / **最近 14 行日志直接显示在屏幕上**） |
| `android/.../MainActivity.kt` | 崩溃处理器 + 日志落盘 + `deviceId` + 启动计数 |
| `android/.../AndroidManifest.xml` | 删除无效的 `EnableImpeller=false`；新增 `ImpellerBackend=opengles` |

### 降级策略（不因为一个可选能力拖死启动）

| 失败的能力 | 降级行为 | 影响 |
|---|---|---|
| MediaSession（audio_service） | 退回裸 `PlaybackHandler` | App 内仍可播放；失去后台播放与遥控媒体键 |
| 安全存储（Keystore） | 降级为普通 SharedPreferences / 跳过会话恢复 | 需重新登录一次 |
| 仓库装配 | 无法降级 | 显示致命错误页 + 重试按钮 |

---

## 五、诊断约定

### 5.1 颜色即信号

> ⚠️ 后续排错请**不要**把 `launch_background` 改回纯黑。

启动窗口背景现在是深蓝 `#14213D`：

| 电视上看到 | 含义 | 下一步 |
|---|---|---|
| **深蓝色一整片** | 卡在启动窗口 —— Flutter 引擎/渲染没起来 | 检查 ABI、Impeller 后端、引擎加载 |
| **引导页（三步列表）** | 引擎正常，已进入 Dart | 看哪一步是 `!` / `X`，即失败原因 |
| **红色「启动失败」框** | 装配阶段致命错误 | 框内有异常原文与堆栈，拍照即可 |
| **正常登录页** | 启动链路已通 | 继续验证登录/播放 |

### 5.2 日志落盘即证据

出问题时按下面的顺序读 `boot.log`：

| 日志里的特征 | 结论 |
|---|---|
| **完全没有 `[dart]` 行** | Dart 根本没跑起来 ⇒ 问题在引擎/渲染层（Impeller 后端、ABI、Vulkan 驱动） |
| 有 `[dart] 步骤N/3 开始` 但**没有对应的完成行** | 崩/卡在这一步 |
| 末尾有 `!!! 未捕获异常 !!!` + 堆栈 | native 崩溃，堆栈直接给出崩溃点 |
| 有 `启动尝试次数 = N（N≥2）` 且本次打印了安全模式 | 说明前一次确实没走完 |

日志文件在 `/storage/emulated/0/Android/data/com.feiniu.tv.music/files/bootlog/boot.log`：
- 电视上有文件管理器 → 直接进 `Android/data/com.feiniu.tv.music/files/bootlog/` 复制出来；
- 找不到 → 引导页上会**直接显示日志路径**和**最近 14 行日志**，拍照即可。

**引导页 + 日志文件 = 电视端仅有的两条证据通道**，出问题时优先回传这两样。
