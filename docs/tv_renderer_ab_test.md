# 海信 E7N Pro / VIDDA：渲染后端 × 插件注册 诊断矩阵

> 现象：APK 安装成功，点开后**只看到 `launch_background` 的深蓝 `#14213D`**，
> **从未出现 BootApp 的「三步初始化」文字**，然后闪退。
>
> 判定：**Flutter 第一帧之前就失败了**。因此本阶段**不排查**飞牛 API、登录、
> MediaSession、播放器、安全存储等业务逻辑 —— 那些代码根本没机会执行。

---

## 零、实机结论（2026-10-03，本轮已收口）

冒烟包与业务包都在海信 E7N Pro / VIDDA 上**跑通了**，先前「黑屏 → 闪退」不再复现。

| 实测 | 结果 |
|---|---|
| **E**（`smoke-plugins`） | 画出 `FLUTTER ENGINE OK`，`已渲染 5 帧` |
| **F**（`smoke-no-plugins`） | 同上 |
| **B**（业务代码 + 默认后端） | 成功显示主 App 的登录页 |
| **C**（业务代码 + GLES 后端） | 同上（**同样成功**） |

由此一次性排除：**引擎启动、渲染后端、ABI 裁剪、插件 native 注册**四项。
E 与业务包走的是同一个 `MainActivity`（会注册全部插件），它没崩，说明崩溃点
不在「注册插件」这个动作上。

登录页能跑出来，还额外证明 `BootApp` 的三步初始化**全部成功**：

- 步骤 1 `MediaSessionService.init()`（audio_service 起前台服务）✅
- 步骤 2 `AuthRepository.restore()`（flutter_secure_storage + Keystore）✅
- 步骤 3 播放与数据仓库装配 ✅

也就是说，「部分电视 ROM 的 Keystore 不可用」「前台服务被 ROM 拒绝」这两个原本
列在高危清单最前面的嫌疑人，在本机**都不成立**。

**结论**：先前失败的两处根因都已在 `e57780a` 改掉 —— ① `AndroidManifest` 里写死的
`ImpellerBackend=opengles`（已删除，改为默认后端）；② 旧版 `MainActivity`（已重写
并加 `BootTrace` 逐步取证）。正式发布候选因此定为 **G =「默认后端 + release」**。

### 0.1 颜色语义（判读「渲染出来没有」的最快依据）

| 颜色 | 出处 | 含义 |
|---|---|---|
| 深蓝 `#14213D` | `launch_background`（启动窗口） | 看到它**且没有字** ⇒ 引擎还没画出第一帧 |
| 近黑 `#0B0B0F` | `buildTvTheme().scaffoldBackgroundColor` | 业务 App 的画布 |

⚠️ 冒烟包把自己的背景也设成了 `#14213D`，所以照片里「有字的深蓝」和「没字的深蓝」
是同一个颜色 —— **判读必须看有没有字，不能只看颜色**。

### 0.2 台电视上已确认可用的配置

- 渲染后端：**默认后端**（`AndroidManifest` 里不写任何渲染 meta-data）
- 插件注册：走标准 `MainActivity` + `super.configureFlutterEngine()`，**正常**
- 安全存储 / 前台服务：**正常**
- `AndroidManifest` 里的 `ImpellerBackend` / `EnableImpeller` 一律**不要写死**
  （写死 GLES 曾直接造成黑屏；写死还会消灭对照组，见 1.2）

---

## 一、先撤回两个错误结论

老实说，之前两轮修复里有两个结论是**错的**，并且第二个错误直接毁掉了实验设计：

### 1.1 「Flutter 3.47 无法关闭 Impeller」

此前的说法是「Android 10+ 的 Skia 后端已被上游移除，`EnableImpeller=false` 无效」。
这个结论来自搜索而非实机验证，**已撤回**。Flutter 3.47 仍然支持 Android 清单里的：

```xml
<meta-data android:name="io.flutter.embedding.android.EnableImpeller"
           android:value="false" />
```

**是否存在可用的非 Impeller 路径，由本次 A/B 实测判定**，不再靠推测。

### 1.2 写死 `ImpellerBackend=opengles` 抹掉了对照组（更严重）

工程里曾经强制：

```xml
<meta-data android:name="io.flutter.embedding.android.ImpellerBackend"
           android:value="opengles" />
```

后果不只是「可能选错后端」，而是**「Impeller 默认后端」这个对照组被直接消灭了** ——
测试退化成只能验证一个后端，根本没有 A/B 可言。而 Debug APK 又会强制执行它。

**现已删除**。`AndroidManifest.xml` 里默认**不带任何渲染 meta-data**（= Flutter
自行选择默认后端），需要哪个后端由诊断构建脚本按变体插入。

### 1.3 「`UncaughtExceptionHandler` 能捕获 native crash」

也是错的，见第四节。

---

## 二、为什么第一帧之前就能失败

第一帧之前能出问题的环节有三个，**必须分离变量逐个排除**：

| 环节 | 说明 | 对应变体 |
|---|---|---|
| **Renderer** | Impeller 默认后端（Vulkan）/ 强制 OpenGL ES / 关闭 Impeller | A / B / C |
| **Plugin Registration** | `GeneratedPluginRegistrant` 在 **native 层**注册插件，发生在第一帧之前 | E vs F |
| **Debug vs Release Engine** | 两者引擎构建与运行时完全不同 | A vs D |

---

## 三、诊断矩阵（7 个 APK）

**全部来自同一 commit、同一份 Dart 业务代码，只有构建配置不同。**
由 `tools/diag/make_variant.py` 生成，脚本只改两处构建配置
（清单里的渲染 meta-data / 显示名 / 启动 Activity，和 Gradle 的 applicationId），
**不改动 `lib/**`、`test/**` 任何一个字节**。

| 变体 | artifact | Renderer | 插件自动注册 | 类型 | Dart 入口 |
|---|---|---|---|---|---|
| **A** | `app-hisense-no-impeller-debug.apk` | `EnableImpeller=false` | 是 | debug | 业务 |
| **B** | `app-hisense-impeller-default-debug.apk` | 无 meta-data（默认后端） | 是 | debug | 业务 |
| **C** | `app-hisense-impeller-gles-debug.apk` | `ImpellerBackend=opengles` | 是 | debug | 业务 |
| **D** | `app-hisense-no-impeller-release.apk` | `EnableImpeller=false` | 是 | **release** | 业务 |
| **E** | `app-hisense-engine-smoke.apk` | 无 meta-data（默认后端） | 是 | debug | 冒烟 |
| **F** | `app-hisense-engine-smoke-no-plugins.apk` | 无 meta-data（默认后端） | **否** | debug | 冒烟 |
| **G** | `app-hisense-release.apk` | 无 meta-data（默认后端） | 是 | **release** | 业务 |

补充说明：

- **E / F 都用「默认后端」**：这是最接近原生 Flutter 模板的配置，作为
  「这台电视能不能跑一个最朴素的 Flutter App」的基线。E 与 F 之间**只差
  插件注册**，这样插件才是唯一变量。
- **F 如何做到不注册插件**：`DiagSmokeActivity` **不调用
  `super.configureFlutterEngine()`**，因此不会经 `GeneratedPluginRegistrant`
  注册 audio_service / just_audio / flutter_secure_storage。只保留一个纯
  `MethodChannel`（不是插件）用于落盘取证。
- **7 个包 applicationId 各不相同**，**可以同时安装、互不覆盖**，
  在电视桌面上的名字分别是 `飞牛A·关Impeller` / `飞牛B·默认后端` /
  `飞牛C·GLES后端` / `飞牛D·Rel关Impeller` / `Smoke·插件版` / `Smoke·无插件` /
  `飞牛·正式版`（G）。这样**一轮 U 盘拷入即可全部装完**，不必装一个卸一个。
- **G 是正式发布候选**（`com.feiniu.tv.music.rel`，默认后端 + release）：
  7 个包里唯一「配置已在真机验证 ＋ release 构建 ＋ 业务代码」的组合。
  D（no_impeller + release）保留作对照，不用于发布。
- **只打包 ARM（`android-arm` + `android-arm64`）**：电视都是 ARM，x86_64 只服务
  模拟器；去掉它每个包小约 1/3。该设置对所有变体完全一致，不构成混淆变量。

### 3.1 从哪里下载这 7 个 APK

GitHub 的 **Artifacts 下载接口必须登录**，即使仓库是公开的。所以除了当次运行页
（`Actions → Phase1 CI → 该次运行 → 页面底部 Artifacts`）之外，另有一条
**匿名可用的网址通道**：

```
https://github.com/xch1996911-ai/feiniu-tv-music/tree/release/release
```

该分支由 `.github/workflows/publish-diag.yml` **独占**维护，包含全部 7 个 APK
以及 `fnos_api_probe.exe`、`MANIFEST.txt`、`BUILD_INFO.txt`。

- **超过 90MB 的包以 `.zip` 形式入库**（Git 单文件硬上限 100MB）：解压即得 `.apk`。
  7 个包里 D 与 G（release，约 34MB）是裸 `.apk`，其余 5 个 debug 包都是 `.zip`。
- 发布方式（**不重新构建**，只把已完成的运行里那批产物搬运过去）：

```bash
git push --force origin main:publish-diag        # 用最近一次成功的 Phase1 CI 产物发布
```

> 触发时机很重要：**必须等本轮 CI 成功之后**再推这个分支。
> 脚本只认「最近一次**成功**的 Phase1 CI 运行」，若在源运行成功前推，
> 它会挑到更早的那次运行、产物名对不上，于是拒绝发布（`exit 1`）——这是刻意的保护。
>
> `release` 分支**只允许这一个 job 写**。曾经 `ci.yml` 里还有一个
> `release-bundle` job 也往这个分支 force push，会把 5 个 debug 包整批抹掉，
> 让用户手里的链接在每次 CI 之后失效；该 job 已删除。

---

## 四、取证边界（这一条最容易搞错）

`BootTrace.installCrashHandler()` 装的是
`Thread.setDefaultUncaughtExceptionHandler`，它**只能可靠捕获 Java/Kotlin
未捕获异常**。它**不是** native crash 捕获器：

**它捕获不到** ——
`SIGSEGV`、`SIGABRT`、`libflutter.so` 崩溃、`libGLESv2.so` / Vulkan 驱动崩溃、
任何 native abort。

这些只会出现在 **`adb logcat`** 与 **`/data/tombstones/`** 里。

> 因此：**`boot.log` 里没有异常堆栈 ≠ 没有 native crash。**
> `boot.log` 的用途是回答「程序执行到了哪一步」，不是提供 native 堆栈。

---

## 五、`boot.log` 里会看到什么

每个包的路径独立（applicationId 不同）：

```
/storage/emulated/0/Android/data/<applicationId>/files/bootlog/boot.log
```

| 变体 | applicationId |
|---|---|
| A | `com.feiniu.tv.music.diaga` |
| B | `com.feiniu.tv.music.diagb` |
| C | `com.feiniu.tv.music.diagc` |
| D | `com.feiniu.tv.music.diagd` |
| E | `com.feiniu.tv.music.smoke` |
| F | `com.feiniu.tv.music.smokenp` |

原生侧逐点记录（业务变体走 `MainActivity`，F 走 `DiagSmokeActivity`）：

```
MainActivity.onCreate 开始 · Android <版本> (API <n>) · ABI <abi 列表>
启动尝试次数 = 1（连续 2 次未走完则自动进入安全模式）
super.onCreate 之前
super.onCreate 返回（Flutter 引擎已启动）
configureFlutterEngine 开始
super.configureFlutterEngine 返回（插件注册完成）      ← F 变体没有这一行
MethodChannel(feiniu/boot) 注册完成
```

Dart 侧（业务入口 `lib/main.dart`）：

```
[dart] ======== App 启动 ========
[dart] Dart main() entered
[dart] runApp before
[dart] runApp after
[dart] first frame callback                            ← 第一帧真的交出去了
[dart] 引导流程开始
[dart] 步骤1/3 开始：播放引擎
...
```

冒烟入口（E / F）：
```
[dart] [smoke] Dart main() entered
[dart] [smoke] DIAG_TAG=smoke-plugins / smoke-no-plugins
[dart] [smoke] runApp before
[dart] [smoke] runApp after
[dart] [smoke] first frame callback
```

### 判读表

| `boot.log` 特征 | 结论 |
|---|---|
| **一行 `[dart]` 都没有** | Dart **根本没执行** ⇒ 引擎 / 渲染 / 插件注册层（在最前面就死了） |
| 有 `[dart] runApp after`，无 `first frame callback` | 引擎起来了，但**第一帧画不出来** ⇒ Renderer / GPU 驱动 |
| 有 `first frame callback` 但屏幕仍是深蓝 | 渲染与显示层不一致（较少见，需看 logcat） |
| 停在 `super.onCreate 返回` 之前 | 引擎启动阶段失败（ABI 不匹配、engine 加载失败） |
| 停在 `super.configureFlutterEngine 返回` 之前 | **插件注册**阶段崩溃 ⇒ 对照 F 变体 |
| 有 `!!! Java 未捕获异常 !!!` + 堆栈 | Java/Kotlin 层异常，堆栈可用 |
| 无上述任何异常行 | ⚠️ 仍可能是 **native crash**，需 logcat / tombstone |

---

## 六、建议的测试顺序（从信息量最大开始）

1. **先装 E（`Smoke·插件版`）** —— 最朴素基线。
   - 能显示 `FLUTTER ENGINE OK` ⇒ 引擎 + 渲染链路没问题，问题在业务代码 / 插件 / 启动时序。
   - 仍是深蓝或闪退 ⇒ 直接进第 2 步。
2. **再装 F（`Smoke·无插件`）**
   - **E 失败但 F 成功** ⇒ 问题在**插件注册**（native 层）。
   - **E、F 都失败** ⇒ 问题在**引擎 / 渲染 / ABI**，与插件无关。
3. **然后装 B（默认后端）→ C（GLES）→ A（关 Impeller）**
   - 三个都失败 ⇒ 后端不是根因，回到第 2 步结论。
   - 只有某个成功 ⇒ 该后端就是答案（例如只有 C 成功 ⇒ Vulkan 驱动有问题）。
4. **最后装 D（release）** —— 与 A 只差构建类型。
   - A 成功但 D 失败 ⇒ Debug/Release 引擎差异（较少见）。
   - A 失败但 D 成功 ⇒ 之前所有 Debug 结论都要打折，必须以 D 为准。

> 每一轮都建议把 `boot.log` 拷出来（引导页上会直接显示路径与最近 14 行日志，
> 拍照也可）。**没有日志的结论一律算推测。**

---

## 七、复现 / 重新生成

```bash
python3 tools/diag/make_variant.py --list          # 打印矩阵
python3 tools/diag/make_variant.py A               # 应用变体 A（只改构建配置）
flutter build apk --debug --target-platform android-arm,android-arm64 -t lib/main.dart
python3 tools/diag/make_variant.py --revert        # 还原为默认配置
```

CI 里由 `.github/workflows/ci.yml` 顺序构建 7 个变体并分别上传，
同时产出 `MANIFEST.txt`（每个 APK 的 Renderer / 插件注册 / applicationId /
字节数 / sha256）。

构建完成后，`.github/workflows/publish-diag.yml` 可把这 7 个产物推到 `release`
分支，使它们能匿名下载（见 3.1）。
