package dev.chuk.betterbahn

import android.app.Activity
import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val OAUTH_CHANNEL = "dev.chuk.betterbahn/oauth"
        private const val OAUTH_REQUEST = 7041
    }

    private var pendingOAuthResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, OAUTH_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "authenticate") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }

                val url = call.argument<String>("url")
                val callbackScheme = call.argument<String>("callbackUrlScheme")
                if (url.isNullOrBlank() || callbackScheme.isNullOrBlank()) {
                    result.error("INVALID_ARGUMENT", "OAuth URL or callback scheme is missing", null)
                    return@setMethodCallHandler
                }
                if (pendingOAuthResult != null) {
                    result.error("AUTH_IN_PROGRESS", "An OAuth login is already in progress", null)
                    return@setMethodCallHandler
                }

                pendingOAuthResult = result
                startActivityForResult(
                    OAuthManagementActivity.createIntent(this, url, callbackScheme),
                    OAUTH_REQUEST,
                )
            }
    }

    @Deprecated("Deprecated in Android, still required by FlutterActivity's result dispatch")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != OAUTH_REQUEST) return

        val result = pendingOAuthResult ?: return
        pendingOAuthResult = null
        when (resultCode) {
            Activity.RESULT_OK -> {
                val callbackUrl = data?.getStringExtra(OAuthManagementActivity.EXTRA_CALLBACK_URL)
                if (callbackUrl == null) {
                    result.error("FAILED", "Authentication returned no callback URL", null)
                } else {
                    result.success(callbackUrl)
                }
            }
            else -> result.error("CANCELED", "User canceled authentication", null)
        }
    }
}
