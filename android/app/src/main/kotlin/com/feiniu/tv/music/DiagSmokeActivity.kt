package com.feiniu.tv.music

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * **诊断专用**最小 Activity：刻意不注册任何 Flutter 插件。
 *
 * ## 存在的唯一理由
 *
 * `FlutterActivity.configureFlutterEngine()` 的默认实现会通过反射调用
 * `io.flutter.plugins.GeneratedPluginRegistrant.registerWith(engine)`，
 * 也就是「所有第三方插件在这一步被注册」。这一步发生在 Dart 第一帧之前，
 * 而且**它在 native 层**——所以即使 Dart 第一帧从未出现，也**不能直接断定
 * 是 Renderer 的问题**，完全可能是某个插件在注册阶段 native crash。
 *
 * 本类**不调用 `super.configureFlutterEngine`**，因此 audio_service /
 * just_audio / flutter_secure_storage 等一律不会被注册。配合
 * `lib/main_engine_smoke.dart`（该入口也不使用任何插件），
 * 就可以把「引擎问题」与「插件注册问题」分开。
 *
 * 只保留一个**纯 MethodChannel**（这不是插件，不经过 GeneratedPluginRegistrant）
 * 用于落盘取证。
 *
 * ⚠️ 本类**只用于诊断**，不能作为正式 App 的启动 Activity。
 */
class DiagSmokeActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "feiniu/boot"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        BootTrace.installCrashHandler(applicationContext)
        BootTrace.note(this, "DiagSmokeActivity.onCreate 开始（诊断版：不注册任何插件）")
        BootTrace.note(this, "super.onCreate 之前")

        super.onCreate(savedInstanceState)

        BootTrace.note(this, "super.onCreate 返回（Flutter 引擎已启动）")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // ⚠️ 关键：**刻意不调用 super.configureFlutterEngine** ——
        // 这是本诊断版本存在的唯一理由。调用它会经 GeneratedPluginRegistrant
        // 注册全部第三方插件，诊断变量就脏了。
        BootTrace.note(this, "configureFlutterEngine 开始（已跳过插件注册）")

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "log" -> {
                        BootTrace.note(this, "[dart] ${call.argument<String>("msg") ?: ""}")
                        result.success(null)
                    }
                    "logPath" -> result.success(BootTrace.logFile(this).absolutePath)
                    // 诊断版不参与业务安全模式，恒定返回 0。
                    "bootAttempts" -> result.success(0)
                    else -> result.notImplemented()
                }
            }

        BootTrace.note(this, "MethodChannel($CHANNEL) 注册完成（插件注册已跳过）")
    }
}
