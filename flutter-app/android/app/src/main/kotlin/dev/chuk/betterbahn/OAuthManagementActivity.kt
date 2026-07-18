package dev.chuk.betterbahn

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.browser.customtabs.CustomTabsClient
import androidx.browser.customtabs.CustomTabsIntent

/**
 * Owns the classic Custom Tab used for OAuth on Android.
 *
 * flutter_web_auth_2 5.x uses Chrome Auth Tab, whose custom-scheme callback
 * does not dismiss reliably on Chrome versions before 141. Bringing this
 * activity back to the front with CLEAR_TOP closes the classic Custom Tab
 * while retaining the browser's normal cookie session.
 */
class OAuthManagementActivity : Activity() {
    companion object {
        const val EXTRA_CALLBACK_URL = "callbackUrl"
        private const val EXTRA_AUTH_URL = "authUrl"
        private const val EXTRA_CALLBACK_SCHEME = "callbackScheme"
        private const val STATE_AUTH_STARTED = "authStarted"

        fun createIntent(context: Context, url: String, callbackScheme: String) =
            Intent(context, OAuthManagementActivity::class.java).apply {
                putExtra(EXTRA_AUTH_URL, url)
                putExtra(EXTRA_CALLBACK_SCHEME, callbackScheme)
            }

        fun createCallbackIntent(context: Context, callbackUrl: String) =
            Intent(context, OAuthManagementActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                putExtra(EXTRA_CALLBACK_URL, callbackUrl)
            }
    }

    private var authStarted = false
    private var callbackUrl: String? = null
    private lateinit var authUrl: String
    private lateinit var callbackScheme: String

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        authUrl = intent.getStringExtra(EXTRA_AUTH_URL).orEmpty()
        callbackScheme = intent.getStringExtra(EXTRA_CALLBACK_SCHEME).orEmpty()
        authStarted = savedInstanceState?.getBoolean(STATE_AUTH_STARTED) ?: false
        if (authUrl.isBlank() || callbackScheme.isBlank()) {
            cancel()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        callbackUrl = intent.getStringExtra(EXTRA_CALLBACK_URL)
    }

    override fun onResume() {
        super.onResume()
        if (isFinishing) return

        if (!authStarted) {
            authStarted = true
            try {
                val customTab = CustomTabsIntent.Builder().build()
                CustomTabsClient.getPackageName(this, emptyList())?.let {
                    customTab.intent.setPackage(it)
                }
                customTab.launchUrl(this, Uri.parse(authUrl))
            } catch (_: Exception) {
                cancel()
            }
            return
        }

        val returnedUrl = callbackUrl
        if (returnedUrl != null && Uri.parse(returnedUrl).scheme == callbackScheme) {
            setResult(RESULT_OK, Intent().putExtra(EXTRA_CALLBACK_URL, returnedUrl))
            finish()
        } else {
            cancel()
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(STATE_AUTH_STARTED, authStarted)
    }

    private fun cancel() {
        setResult(RESULT_CANCELED)
        finish()
    }
}
