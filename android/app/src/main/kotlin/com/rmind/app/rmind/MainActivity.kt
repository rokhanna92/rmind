package com.rmind.app.rmind

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the battery optimisation channel.
 *
 * Android has no plugin-free Dart API for the battery optimisation whitelist,
 * and it is the single setting most likely to silently stop a scheduled alarm
 * from ever firing, so it is worth these few lines rather than a dependency.
 */
class MainActivity : FlutterActivity() {

    private val channelName = "com.rmind.app/battery"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isIgnoringBatteryOptimizations" ->
                    result.success(isIgnoringBatteryOptimizations())
                "requestIgnoreBatteryOptimizations" ->
                    result.success(requestIgnoreBatteryOptimizations())
                "canInstallPackages" -> result.success(canInstallPackages())
                "requestInstallPermission" ->
                    result.success(requestInstallPermission())
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("no_path", "installApk needs a path", null)
                    } else {
                        result.success(installApk(path))
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Whether the user has already allowed this app to install packages.
     *
     * Below API 26 the permission is granted at install time, so there is
     * nothing to ask for.
     */
    private fun canInstallPackages(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return packageManager.canRequestPackageInstalls()
    }

    /** Opens the per app "install unknown apps" screen. */
    private fun requestInstallPermission(): Boolean {
        if (canInstallPackages()) return true
        return try {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                )
            )
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Hands a downloaded APK to the system installer.
     *
     * Android has no silent install for a normal app, by design. The most this
     * can do is open the installer with the file attached, after which the user
     * confirms. The file is passed as a content:// URI because a raw path is
     * rejected from API 24 onward.
     */
    private fun installApk(path: String): Boolean {
        return try {
            val file = File(path)
            if (!file.exists()) return false
            val uri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                file
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * True on API levels that predate the whitelist, since there is nothing
     * there to exempt the app from. Reporting false would strand the user on a
     * setup step they cannot complete.
     */
    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val power = getSystemService(Context.POWER_SERVICE) as? PowerManager
            ?: return true
        return power.isIgnoringBatteryOptimizations(packageName)
    }

    /**
     * Opens the system prompt. The return value only reports whether the
     * screen was launched, because the user makes the actual choice after this
     * call has already returned. Dart re-checks the real state afterwards.
     */
    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (isIgnoringBatteryOptimizations()) return true
        return try {
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName")
                )
            )
            true
        } catch (e: Exception) {
            // Some OEM builds ship without the direct request screen. Fall
            // back to the general list so the user can still get there.
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                true
            } catch (e2: Exception) {
                false
            }
        }
    }
}
