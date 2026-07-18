package dev.chuk.betterbahn

import android.app.Activity
import android.os.Bundle

/** Receives DB, BahnBonus and Träwelling redirects and closes their Custom Tab. */
class OAuthCallbackActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        intent?.data?.toString()?.let { callbackUrl ->
            startActivity(OAuthManagementActivity.createCallbackIntent(this, callbackUrl))
        }
        finish()
    }
}
