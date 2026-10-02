package com.feiniu.tv.music

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
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
 */
class MainActivity : FlutterActivity() {

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
                    "bootAttempts" -> result.success(prefs.getInt(KEY_ATTEMPTS, 0))
                    "markBootOk" -> {
                        prefs.edit().putInt(KEY_ATTEMPTS, 0).apply()
                        BootTrace.note(this, "[dart] 启动完成，崩溃计数已清零")
                        result.success(null)
                    }
                    "deviceId" -> result.success(deviceId())
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
