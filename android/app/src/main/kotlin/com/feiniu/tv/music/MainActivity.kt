package com.feiniu.tv.music

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.os.Bundle
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.SecureRandom
import java.util.Locale

/**
 * 正式主 Activity。
 *
 * 这里塞了两件「非常规」的事，都是为了在没有 adb 的 Android TV 上排错：
 *
 * 1. **启动痕迹落盘**（[BootTrace]）：写到
 *    `getExternalFilesDir(null)/bootlog/boot.log`，Dart 侧经同一渠道写 `[dart] xxx`。
 *    原生侧的节点按「能否定位到卡在哪一步」来设计，逐步记录：
 *    `onCreate 开始` → `super.onCreate 之前` → `super.onCreate 返回` →
 *    `configureFlutterEngine 开始` → `super.configureFlutterEngine 返回（插件注册完成）` →
 *    `MethodChannel 注册完成`。
 * 2. **`deviceId` 走原生 SharedPreferences**（[deviceId]），**不经过 Keystore** ——
 *    部分电视 ROM 上 `EncryptedSharedPreferences` 会在原生层直接崩溃，
 *    Dart 侧 `try/catch` 拦不住；而 deviceId 只是随机标识、非机密。
 * 3. `boot_attempts` 计数供 Dart 侧的「自动安全模式」使用。
 *
 * ⚠️ **关于崩溃取证的边界（重要，别搞错）**：
 * [BootTrace.installCrashHandler] 装的是 `Thread.setDefaultUncaughtExceptionHandler`，
 * **只能可靠捕获 Java/Kotlin 未捕获异常**。它**不是** native crash 捕获器：
 * SIGSEGV / SIGABRT / `libflutter.so` 崩溃 / `libGLESv2.so` / Vulkan 驱动崩溃
 * 都不会经过它，只出现在 `adb logcat` 与 `/data/tombstones/`。
 * 所以 **boot.log 里没有异常堆栈 ≠ 没有 native crash**；
 * boot.log 的用途是回答「执行到了哪一步」，不是提供 native 堆栈。
 *
 * ## ⚠️ 基类必须是 `AudioServiceActivity`，不能是 `FlutterActivity`（V5 根因修复）
 *
 * 实机（图1）启动时报：
 *
 * ```
 * PlatformException(The Activity class declared in your AndroidManifest.xml
 *   is wrong or has not provided the correct FlutterEngine. Please see the
 *   README for instructions., null, null, null)
 * ```
 *
 * 该字符串来自 audio_service 0.18.15 的
 * `AudioServicePlugin.java` → `ClientInterface.onMethodCall`：
 *
 * ```java
 * if (wrongEngineDetected) {
 *   throw new IllegalStateException("The Activity class declared in your ...");
 * }
 * ```
 *
 * 而 `wrongEngineDetected` 的判定在同一文件的 `onAttachedToEngine` 里：
 *
 * ```java
 * FlutterEngine sharedEngine = getFlutterEngine(binding.getActivity());
 * clientInterface.setWrongEngineDetected(
 *     flutterPluginBinding.getBinaryMessenger() != sharedEngine.getDartExecutor());
 * ```
 *
 * 即：**插件注册所在引擎**必须**就是** `AudioServicePlugin.getFlutterEngine()`
 * 返回的那个「共享引擎」。而
 *
 * ```java
 * public class AudioServiceActivity extends FlutterActivity {
 *   @Override public FlutterEngine provideFlutterEngine(@NonNull Context context) {
 *     return AudioServicePlugin.getFlutterEngine(context);  // ← 关键
 *   }
 * }
 * ```
 *
 * 是官方唯一保证「两者是同一个引擎」的方式。本类原先继承裸 `FlutterActivity`，
 * `provideFlutterEngine` 走的是 FlutterActivity 自己新建的引擎，
 * 与 `AudioServicePlugin.getFlutterEngine()` 从 `FlutterEngineCache` 取/新建的
 * 引擎**不是同一个对象** ⇒ `wrongEngineDetected = true` ⇒ 之后每一次
 * audio_service 的 MethodChannel 调用都抛 PlatformException。
 *
 * 危害不止「没有后台播放」：`PlaybackHandler` 继承自 audio_service 的
 * `BaseAudioHandler`，其 `play/pause/skipToNext/...` 全部经由该 MethodChannel
 * 下发 —— 也就是说**前台播放本身也是不可靠的**，只是我们此前把它当成
 * 「降级为本地播放」掩盖过去了。
 *
 * ⚠️ 与之配套的两处 Manifest 错配见 `AndroidManifest.xml`：
 * service 名必须是 `com.ryanheise.audioservice.AudioService`（0.18.x 已无
 * `MediaPlaybackService` 这个类），且必须声明 `MediaButtonReceiver`，否则
 * 遥控媒体键收不到广播。
 */
class MainActivity : AudioServiceActivity() {

    companion object {
        private const val CHANNEL = "feiniu/boot"
        private const val PREFS = "feiniu_boot"
        private const val KEY_ATTEMPTS = "boot_attempts"
        private const val KEY_DEVICE_ID = "device_id"
        private const val DEVICE_ID_RE = "^[a-f0-9]{32}$"
    }

    private val prefs: SharedPreferences
        get() = getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    override fun onCreate(savedInstanceState: Bundle?) {
        // 必须早于 super.onCreate：Flutter 引擎就是在 super.onCreate 里启动的。
        BootTrace.installCrashHandler(applicationContext)
        BootTrace.note(
            this,
            "MainActivity.onCreate 开始 · Android ${Build.VERSION.RELEASE}" +
                " (API ${Build.VERSION.SDK_INT}) · ABI ${Build.SUPPORTED_ABIS.joinToString(",")}"
        )
        bumpBootAttempt()
        BootTrace.note(this, "super.onCreate 之前")

        super.onCreate(savedInstanceState)

        BootTrace.note(this, "super.onCreate 返回（Flutter 引擎已启动）")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        BootTrace.note(this, "configureFlutterEngine 开始")

        // 这一步内部会经 GeneratedPluginRegistrant 注册所有第三方插件。
        super.configureFlutterEngine(flutterEngine)

        BootTrace.note(this, "super.configureFlutterEngine 返回（插件注册完成）")

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "log" -> {
                        BootTrace.note(this, "[dart] ${call.argument<String>("msg") ?: ""}")
                        result.success(null)
                    }
                    "logPath" -> result.success(BootTrace.logFile(this).absolutePath)
                    // 应用内部数据目录。Dart 侧用它落盘**曲库索引**等
                    // 非敏感元数据（`filesDir` 是应用私有目录，不需要任何
                    // 存储权限，也不会被其他 App 读到）。
                    //
                    // ⚠️ 为什么不引入 `path_provider`：
                    //    本项目已有一条经过实机验证的原生通道，加个方法即可；
                    //    多一个带原生实现的依赖，就多一份「在某个电视 ROM 上
                    //    插件注册失败」的风险 —— 而这台机器上没有 adb，
                    //    代价是一轮完整的「下载 APK → 拷 U 盘 → 装电视」。
                    //    凭据仍然只走 `flutter_secure_storage`（见 SecureStore）。
                    "dataDir" -> result.success(filesDir.absolutePath)
                    "bootAttempts" -> result.success(prefs.getInt(KEY_ATTEMPTS, 0))
                    "markBootOk" -> {
                        prefs.edit().putInt(KEY_ATTEMPTS, 0).apply()
                        BootTrace.note(this, "[dart] 启动完成，崩溃计数已清零")
                        result.success(null)
                    }
                    "deviceId" -> result.success(deviceId())
                    // 「后台继续播放」：只把 Activity/task 退到后台。
                    // ⚠️ 这里**不做**任何音频操作 —— audio_service 的前台服务
                    //    本来就不依赖 Activity 在前台，返回 true 后音频继续、
                    //    媒体键继续可用。Dart 侧（AppExit.moveToBackground）
                    //    负责保证调用前没有 pause/stop/dispose。
                    "moveTaskToBack" -> {
                        val moved = moveTaskToBack(true)
                        BootTrace.note(this, "[dart] moveTaskToBack -> $moved")
                        result.success(moved)
                    }
                    // 「退出并停止播放」的最后一步：结束 Activity 并从最近任务移除。
                    // ⚠️ 调用顺序由 Dart 侧保证：先停音源、广播 MediaSession idle
                    //    （撤前台通知/停服务）、停遥控 HTTP/WS 服务，**最后**才到这里。
                    //    这里不做任何业务清理 —— 那些是 Dart 侧的职责，
                    //    本方法只负责「窗口层」的收尾。
                    "exitApp" -> {
                        BootTrace.note(this, "[dart] exitApp（finishAndRemoveTask）")
                        result.success(null)
                        finishAndRemoveTask()
                    }
                    else -> result.notImplemented()
                }
            }

        BootTrace.note(this, "MethodChannel($CHANNEL) 注册完成")
    }

    // ── 启动计数（自动安全模式的依据） ────────────────────────────────────

    private fun bumpBootAttempt() {
        val n = prefs.getInt(KEY_ATTEMPTS, 0) + 1
        prefs.edit().putInt(KEY_ATTEMPTS, n).apply()
        BootTrace.note(this, "启动尝试次数 = $n（连续 2 次未走完则自动进入安全模式）")
    }

    // ── deviceId（不经过 Keystore） ───────────────────────────────────────

    private fun deviceId(): String {
        val cached = prefs.getString(KEY_DEVICE_ID, null)
        if (cached != null && Regex(DEVICE_ID_RE).matches(cached)) {
            BootTrace.note(this, "复用已持久化 deviceId ${cached.take(8)}…")
            return cached
        }

        val bytes = ByteArray(16)
        SecureRandom().nextBytes(bytes)
        val id = bytes.joinToString("") {
            String.format(Locale.US, "%02x", it.toInt() and 0xff)
        }
        prefs.edit().putString(KEY_DEVICE_ID, id).apply()
        BootTrace.note(this, "生成新 deviceId ${id.take(8)}…（SharedPreferences，不走 Keystore）")
        return id
    }
}
