package com.feiniu.tv.music

import android.content.Context
import android.util.Log
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 启动痕迹落盘（Android TV 没有 adb 时唯一的取证通道）。
 *
 * ## 边界必须记清楚（这里曾经搞错过）
 *
 * 它只回答一个问题：**程序执行到了哪一步**。
 * 它**不是** native crash 收集器 —— [installCrashHandler] 装的是
 * `Thread.setDefaultUncaughtExceptionHandler`，只能可靠捕获
 * **Java/Kotlin 未捕获异常**。下面这些**不会**经过它：
 *
 * - `SIGSEGV` / `SIGABRT` 等信号导致的崩溃
 * - `libflutter.so` 内部崩溃
 * - `libGLESv2.so` / Vulkan 驱动崩溃
 * - 任何 native 层 abort
 *
 * 因此：**boot.log 里没有异常堆栈，不等于没有 native crash**。
 * native crash 仍然只能靠 `adb logcat` 与 `/data/tombstones/` 判定。
 *
 * ## 另一个边界
 *
 * 任何写日志的动作都必须「绝不抛异常」：它自己崩了，证据就没了。
 */
internal object BootTrace {
    private const val TAG = "FeiNiuTV"
    private const val DIR = "bootlog"
    private const val NAME = "boot.log"

    private var handlerInstalled = false

    /** 日志文件。外部存储不可用时退回应用私有目录，保证一定写得进去。 */
    fun logFile(ctx: Context): File {
        val base = ctx.getExternalFilesDir(null) ?: ctx.filesDir
        val dir = File(base, DIR)
        if (!dir.exists()) {
            dir.mkdirs()
        }
        return File(dir, NAME)
    }

    /** 写一行启动痕迹：文件 + logcat，两者都尽力而为、绝不抛异常。 */
    @Synchronized
    fun note(ctx: Context, message: String) {
        try {
            logFile(ctx).appendText("${stamp()}  $message\n")
        } catch (_: Throwable) {
            // 落盘失败不影响运行。
        }
        try {
            Log.i(TAG, message)
        } catch (_: Throwable) {
            // 忽略。
        }
    }

    /**
     * 安装 Java/Kotlin 未捕获异常处理器。
     *
     * ⚠️ **不是 native crash 捕获器**（详见类注释）。
     * 它只能在「Java 层抛出了未捕获异常」时补上一份堆栈，
     * 与 native 崩溃无关。
     */
    @Synchronized
    fun installCrashHandler(ctx: Context) {
        if (handlerInstalled) {
            return
        }
        handlerInstalled = true
        val app = ctx.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                val sw = StringWriter()
                throwable.printStackTrace(PrintWriter(sw))
                note(app, "!!! Java 未捕获异常 · thread=${thread.name} !!!\n$sw")
            } catch (_: Throwable) {
                // 崩溃处理器自身绝不能抛，否则会掩盖真实崩溃。
            }
            previous?.uncaughtException(thread, throwable)
        }
    }

    private fun stamp(): String =
        SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US).format(Date())
}
