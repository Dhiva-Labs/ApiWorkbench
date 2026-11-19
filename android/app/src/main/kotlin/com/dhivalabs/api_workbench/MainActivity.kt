package com.dhivalabs.api_workbench

import android.media.MediaPlayer
import android.os.Bundle
import androidx.activity.enableEdgeToEdge
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity rather than FlutterActivity: enableEdgeToEdge() is
// an extension of androidx.activity.ComponentActivity, which FlutterActivity
// is not.
class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Draw behind the status and navigation bars on every Android version,
        // as Android 15 and later force for apps that target 35 or higher.
        // Flutter reports the bar sizes through MediaQuery, which the screens'
        // SafeAreas use to keep controls clear of the bars.
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "apiworkbench/sound")
            .setMethodCallHandler { call, result ->
                if (call.method == "play") {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("no_path", "Missing sound path", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val player = MediaPlayer()
                        player.setDataSource(path)
                        player.setOnPreparedListener { it.start() }
                        player.setOnCompletionListener { it.release() }
                        player.setOnErrorListener { p, _, _ -> p.release(); true }
                        player.prepareAsync()
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("play_failed", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }
}
