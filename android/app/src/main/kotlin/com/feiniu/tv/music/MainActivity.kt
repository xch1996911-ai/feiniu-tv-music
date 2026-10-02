package com.feiniu.tv.music

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.security.SecureRandom
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 主 Activity。
 *
 * ## 为什么这里塞了「崩溃日志落盘」和「deviceId」
 *
 * Android TV 盒子普遍没有 adb，App 黑屏/闪退时拿不到 logcat，只能靠落盘日志
 * 定位。所以：
 *
 * 1. [installCrashHandler] 在**任何 Flutter 代码之前**装上默认未捕获异常处理器，
 *    把崩溃堆栈写进 `getExternalFilesDir(null)/bootlog/boot.log`。
 *    这样即使是 Flutter 引擎启动阶段的 native 崩溃，也能留下最后一步的痕迹。
 * 2. [note] 把原生关键节点（onCreate / super.onCreate 返回 / 通道注册）也写进
 *    同一个文件。判定规则很简单：
 *    - 日志里一行 `[dart]` 都没有 ⇒ 问题在引擎/渲染层，Dart 还没跑起来；
 *    - 有 `[dart] 步骤N 开始` 但没有对应的「完成」⇒ 卡/崩在这一步。
 * 3. `deviceId` 走原生 `SharedPreferences`（[deviceId]），**不经过 Keystore**。
 *    部分电视 ROM 上 `EncryptedSharedPreferences` 会在原生层直接崩溃，Dart 侧
 *    try/catch 拦不住；而 deviceId 只是随机标识、非机密，不值得冒险。
 * 4. `boot_attempts` 计数用于**自动安全模式**：连续两次启动没走完，
 *    下一次 Dart 侧会跳过 audio_service 与安全存储，优先保证能看到界面。
 *
 * manifest 里 `android:name="${applicationName}"`（Flutter 模板默认）保持不变，
 * 未引入自定义 Application，尽量缩小改动面。
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "feiniu/boot"
        private const val PREFS = "feiniu_boot"
        private const val KEY_ATTEMPTS = "boot_attempts"
        private const val KEY_DEVICE_ID = "device_id"
        private const val TAG = "FeiNiuTV"
        private const val DEVICE_ID_RE = "^[a-f0-9]{32}$"
        private const val LOG_DIR = "bootlog"
        private const val LOG_NAME = "boot.log"
    }

    private val prefs: SharedPreferences
        get() = getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    override fun onCreate(savedInstanceState: Bundle?) {
        // 必须早于 super.onCreate：Flutter 引擎就是在 super.onCreate 里启动的。
        installCrashHandler()
        note(
            "MainActivity.onCreate 开始 · Android ${Build.VERSION.RELEASE}" +
                " (API ${Build.VERSION.SDK_INT}) · ABI ${Build.SUPPORTED_ABIS.joinToString(",")}"
        )
        bumpBootAttempt()

        super.onCreate(savedInstanceState)

        note("super.onCreate 返回（Flutter 引擎已启动）")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "log" -> {
                        note("[dart] ${call.argument<String>("msg") ?: ""}")
                        result.success(null)
                    }
                    "logPath" -> result.success(logFile().absolutePath)
                    "bootAttempts" -> result.success(prefs.getInt(KEY_ATTEMPTS, 0))
                    "markBootOk" -> {
                        prefs.edit().putInt(KEY_ATTEMPTS, 0).apply()
                        note("[dart] 启动完成，崩溃计数已清零")
                        result.success(null)
                    }
                    "deviceId" -> result.success(deviceId())
                    else -> result.notImplemented()
                }
            }

        note("MethodChannel($CHANNEL) 已注册")
    }

    // ── 崩溃取证 ─────────────────────────────────────────────────────────

    private fun installCrashHandler() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                val sw = StringWriter()
                throwable.printStackTrace(PrintWriter(sw))
                note("!!! 未捕获异常 · thread=${thread.name} !!!\n$sw")
            } catch (_: Throwable) {
                // 崩溃处理器自身绝对不能抛，否则会掩盖真实崩溃。
            }
            previous?.uncaughtException(thread, throwable)
        }
    }

    @Synchronized
    private fun note(message: String) {
        try {
            logFile().appendText("${stamp()}  $message\n")
        } catch (_: Throwable) {
            // 落盘失败不影响运行。
        }
        try {
            Log.i(TAG, message)
        } catch (_: Throwable) {
            // 忽略。
        }
    }

    private fun stamp(): String =
        SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US).format(Date())

    private fun logFile(): File {
        val base = getExternalFilesDir(null) ?: filesDir
        val dir = File(base, LOG_DIR)
        if (!dir.exists()) {
            dir.mkdirs()
        }
        return File(dir, LOG_NAME)
    }

    // ── 启动计数（自动安全模式的依据） ────────────────────────────────────

    private fun bumpBootAttempt() {
        val n = prefs.getInt(KEY_ATTEMPTS, 0) + 1
        prefs.edit().putInt(KEY_ATTEMPTS, n).apply()
        note("启动尝试次数 = $n（连续 2 次未走完则自动进入安全模式）")
    }

    // ── deviceId（不经过 Keystore） ───────────────────────────────────────

    private fun deviceId(): String {
        val cached = prefs.getString(KEY_DEVICE_ID, null)
        if (cached != null && Regex(DEVICE_ID_RE).matches(cached)) {
            note("复用已持久化 deviceId ${cached.take(8)}…")
            return cached
        }

        val bytes = ByteArray(16)
        SecureRandom().nextBytes(bytes)
        val id = bytes.joinToString("") {
            String.format(Locale.US, "%02x", it.toInt() and 0xff)
        }
        prefs.edit().putString(KEY_DEVICE_ID, id).apply()
        note("生成新 deviceId ${id.take(8)}…（写入 SharedPreferences，不走 Keystore）")
        return id
    }
}
