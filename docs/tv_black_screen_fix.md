# Android TV 黑屏问题：根因与诊断约定

> 现象：APK 在电视上安装成功，点开**纯黑屏，什么都不显示**，无报错、无界面。
> 本文记录根因、修复方案，以及后续排错时必须遵守的「颜色即信号」约定。

---

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

任一种情况发生，`runApp` 就**永远不执行**。

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

### 1.4 次因：Impeller / Vulkan 驱动

部分 Android TV 盒子的 Vulkan 驱动不完整，Impeller 渲染后端下会出现
「进程存活、音频正常，画面全黑」。已显式关闭 Impeller 回退 Skia。

---

## 二、修复

| 文件 | 改动 |
|---|---|
| `lib/main.dart` | **`runApp` 之前不再有任何 `await`**；同步 `runApp(const BootApp())`；`runZonedGuarded` + `FlutterError.onError` 兜底 |
| `lib/boot/boot_screen.dart`（新增） | 启动引导页：三步初始化逐步 `try/catch` **+ 超时**，可降级；失败原因**画在屏幕上** |
| `lib/app/theme.dart`（新增） | 引导页与主界面共用主题，避免切换时样式跳变 |
| `lib/app/app.dart` | 改用共享主题；修掉 `dispose()` 里 `context.read` 的不安全用法 |
| `lib/playback/media_session_service.dart` | `init()` 内置 15s 超时（防「永久挂起」） |
| `lib/services/secure_store.dart` | 加密存储失败自动降级为普通存储并重试一次 |
| `android/.../AndroidManifest.xml` | 补 `FOREGROUND_SERVICE_MEDIA_PLAYBACK`；关闭 Impeller |
| `android/.../res/drawable/launch_background.xml` | 纯黑 → 深蓝（见下） |

### 降级策略（不因为一个可选能力拖死启动）

| 失败的能力 | 降级行为 | 影响 |
|---|---|---|
| MediaSession（audio_service） | 退回裸 `PlaybackHandler` | App 内仍可播放；失去后台播放与遥控媒体键 |
| 安全存储（Keystore） | 降级为普通 SharedPreferences | 需重新登录一次；deviceId 会重新生成 |
| 仓库装配 | 无法降级 | 显示致命错误页 + 重试按钮 |

---

## 三、诊断约定：颜色即信号

> ⚠️ 后续排错请**不要**把 `launch_background` 改回纯黑。

启动窗口背景现在是深蓝 `#14213D`：

| 电视上看到 | 含义 | 下一步 |
|---|---|---|
| **深蓝色一整片** | 卡在启动窗口 —— Flutter 引擎/渲染没起来 | 检查 ABI、Impeller、引擎加载 |
| **引导页（三步列表）** | 引擎正常，已进入 Dart | 看哪一步是 `!` / `X`，即失败原因 |
| **红色「启动失败」框** | 装配阶段致命错误 | 框里有异常原文与堆栈，拍照即可 |
| **正常登录页** | 启动链路已通 | 继续验证登录/播放 |

引导页还会显示 `Dart 版本` 与`系统版本`，用于判断是否是特定 ROM 的兼容问题。

电视上没有 adb 时，**引导页 / 红色错误框就是唯一的证据通道**，
出问题时直接拍照回传即可。
