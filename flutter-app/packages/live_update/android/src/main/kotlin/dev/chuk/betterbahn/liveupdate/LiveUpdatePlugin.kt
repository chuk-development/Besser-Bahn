package dev.chuk.betterbahn.liveupdate

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The Live Update channel, as a plugin rather than something hung off
 * `MainActivity`.
 *
 * That is the whole point: the trip has to keep updating while the phone is in a
 * pocket and the UI is gone. The background tracker runs in a headless engine,
 * and a handler registered in `MainActivity.configureFlutterEngine` simply does
 * not exist there — the Live Update would go stale exactly when it matters most.
 * A `FlutterPlugin` attaches to *every* engine, and posting a notification needs
 * only a `Context`.
 */
class LiveUpdatePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.NewIntentListener {

    companion object {
        private const val CHANNEL = "dev.chuk.betterbahn/live_update"

        /** Intent extra on the chip's tap: the key of the trip it shows. */
        const val EXTRA_TRIP_KEY = "dev.chuk.betterbahn.LIVE_TRIP_KEY"
    }

    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var activityBinding: ActivityPluginBinding? = null

    /**
     * The trip key a tap on the chip started (or resumed) the activity with.
     * Taken once by Dart (`takeLaunchTripKey`) so a later resume doesn't jump
     * to the trip again.
     */
    private var pendingTripKey: String? = null

    /**
     * Swiping a Live Update away has to stick — otherwise the next poll posts it
     * again a minute later and the app is arguing with the rider. Registered at
     * runtime rather than in the manifest on purpose: only the process that
     * posted the Live Update can suppress the next one, and once that process is
     * gone there is nothing left to suppress.
     */
    private val dismissReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == TripLiveUpdate.ACTION_DISMISSED) {
                channel?.invokeMethod("onDismissed", null)
            }
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val ctx = binding.applicationContext
        context = ctx
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        val filter = IntentFilter(TripLiveUpdate.ACTION_DISMISSED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Our own delete intent is the only sender; exporting it would let
            // any app on the device switch the trip display off.
            ctx.registerReceiver(dismissReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            ctx.registerReceiver(dismissReceiver, filter)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        runCatching { binding.applicationContext.unregisterReceiver(dismissReceiver) }
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    // --- Tap on the chip → open that trip ------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addOnNewIntentListener(this)
        // Cold start from the chip: the extra rides on the launch intent.
        consumeTripKey(binding.activity.intent)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
    }

    /** App already running (SINGLE_TOP): the tap arrives here. */
    override fun onNewIntent(intent: Intent): Boolean {
        val key = consumeTripKey(intent) ?: return false
        channel?.invokeMethod("onTripTapped", key)
        return false
    }

    private fun consumeTripKey(intent: Intent?): String? {
        val key = intent?.getStringExtra(EXTRA_TRIP_KEY)?.takeIf { it.isNotEmpty() }
        if (key != null) {
            pendingTripKey = key
            intent.removeExtra(EXTRA_TRIP_KEY)
        }
        return key
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context
        if (ctx == null) {
            result.error("NO_CONTEXT", "Plugin is not attached", null)
            return
        }
        when (call.method) {
            "isSupported" -> result.success(TripLiveUpdate.isSupported(ctx))
            "isPromoted" -> result.success(TripLiveUpdate.isPromoted(ctx))
            "hasMetricStyle" -> result.success(Api37.available)
            "takeLaunchTripKey" -> {
                result.success(pendingTripKey)
                pendingTripKey = null
            }
            "cancel" -> {
                TripLiveUpdate.cancel(ctx)
                result.success(null)
            }
            "post" -> {
                val posted = TripLiveUpdate.post(ctx, spec(ctx, call))
                result.success(
                    mapOf("promoted" to posted.promoted, "style" to posted.style)
                )
            }
            else -> result.notImplemented()
        }
    }

    private fun spec(ctx: Context, call: MethodCall): TripLiveUpdate.Spec {
        val segments = (call.argument<List<Map<String, Any>>>("segments") ?: emptyList())
            .map {
                TripLiveUpdate.Segment(
                    minutes = (it["minutes"] as? Number)?.toInt() ?: 1,
                    color = (it["color"] as? Number)?.toInt() ?: 0xFF9AA0A6.toInt(),
                )
            }
        val metrics = (call.argument<List<Map<String, Any?>>>("metrics") ?: emptyList())
            .mapNotNull { metric(it) }

        // Tapping the chip opens the app, which lands on the trip — the same
        // place the ordinary trip notifications go.
        val launch = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
        val tripKey = call.argument<String>("tripKey")
        val contentIntent = launch?.let {
            if (!tripKey.isNullOrEmpty()) it.putExtra(EXTRA_TRIP_KEY, tripKey)
            PendingIntent.getActivity(
                ctx,
                0,
                it.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        val deleteIntent = PendingIntent.getBroadcast(
            ctx,
            0,
            Intent(TripLiveUpdate.ACTION_DISMISSED).setPackage(ctx.packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val iconName = call.argument<String>("smallIcon") ?: "ic_stat_besserbahn"
        val iconRes = ctx.resources.getIdentifier(iconName, "drawable", ctx.packageName)

        return TripLiveUpdate.Spec(
            title = call.argument<String>("title") ?: "",
            text = call.argument<String>("text") ?: "",
            chipText = call.argument<String>("chipText"),
            subText = call.argument<String>("subText"),
            nowbarPrimary = call.argument<String>("nowbarPrimary"),
            nowbarSecondary = call.argument<String>("nowbarSecondary"),
            chipExpandedText = call.argument<String>("chipExpandedText"),
            segments = segments,
            transferPoints = call.argument<List<Int>>("points") ?: emptyList(),
            transferColor =
                call.argument<Number>("transferColor")?.toInt() ?: 0xFFF29D38.toInt(),
            progressMinutes = call.argument<Number>("progress")?.toInt() ?: 0,
            etaEpochMillis = call.argument<Number>("etaEpochMillis")?.toLong(),
            smallIconRes = if (iconRes != 0) iconRes else android.R.drawable.stat_notify_chat,
            contentIntent = contentIntent,
            deleteIntent = deleteIntent,
            metrics = metrics,
            criticalMetric = call.argument<Number>("criticalMetric")?.toInt() ?: -1,
            titleSemantic = call.argument<Number>("titleSemantic")?.toInt()
                ?: SemanticStyle.UNSPECIFIED,
            style = when (call.argument<String>("style")) {
                "progress" -> TripLiveUpdate.StyleMode.PROGRESS
                "metric" -> TripLiveUpdate.StyleMode.METRIC
                else -> TripLiveUpdate.StyleMode.AUTO
            },
        )
    }

    private fun metric(map: Map<String, Any?>): TripLiveUpdate.Metric? {
        val label = map["label"] as? String ?: return null
        val kind = when (map["kind"] as? String) {
            "count" -> TripLiveUpdate.MetricKind.COUNT
            "clock" -> TripLiveUpdate.MetricKind.CLOCK
            "text" -> TripLiveUpdate.MetricKind.TEXT
            else -> return null
        }
        return TripLiveUpdate.Metric(
            label = label,
            kind = kind,
            number = (map["number"] as? Number)?.toInt() ?: 0,
            text = map["text"] as? String,
            unit = map["unit"] as? String,
            semanticStyle = (map["semantic"] as? Number)?.toInt() ?: SemanticStyle.UNSPECIFIED,
        )
    }
}
