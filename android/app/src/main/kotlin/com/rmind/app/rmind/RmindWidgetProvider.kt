package com.rmind.app.rmind

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.os.SystemClock
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * The home screen widget: the next reminder, plus the running workout session
 * when there is one.
 *
 * This class renders and nothing else. Every string it draws was formatted in
 * Dart by WidgetService and saved through home_widget, because the launcher
 * process cannot see the app's formatting helpers and a second copy of them
 * here would drift. The one number that crosses is the session start, which a
 * Chronometer needs so it can tick without the app being woken at all.
 */
class RmindWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        // Read as strings throughout, matching what Dart saves. Reading a key
        // back as the wrong SharedPreferences type throws, and a widget that
        // throws in onUpdate shows the launcher's "problem loading" tile.
        val emptyMessage = widgetData.getString(KEY_EMPTY, "").orEmpty()
        val whenLine = widgetData.getString(KEY_WHEN, "").orEmpty()
        val title = widgetData.getString(KEY_TITLE, "").orEmpty()
        val isAlarm = widgetData.getString(KEY_IS_ALARM, "").orEmpty() == TRUE
        val sessionName = widgetData.getString(KEY_SESSION_NAME, "").orEmpty()
        val startedAtMs =
            widgetData.getString(KEY_SESSION_STARTED_MS, "")?.toLongOrNull() ?: 0L
        val sessionRunning =
            widgetData.getString(KEY_SESSION_RUNNING, "").orEmpty() == TRUE &&
                startedAtMs > 0L

        val hasReminder = whenLine.isNotEmpty()

        appWidgetIds.forEach { widgetId ->
            val views =
                RemoteViews(context.packageName, R.layout.rmind_widget).apply {
                    setOnClickPendingIntent(
                        R.id.rmind_widget_root,
                        HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java),
                    )

                    setTextViewText(R.id.rmind_widget_when, whenLine)
                    setTextViewText(R.id.rmind_widget_title, title)
                    setViewVisibility(R.id.rmind_widget_when, visibility(hasReminder))
                    setViewVisibility(
                        R.id.rmind_widget_title,
                        visibility(hasReminder && title.isNotEmpty()),
                    )
                    setViewVisibility(
                        R.id.rmind_widget_alarm,
                        visibility(hasReminder && isAlarm),
                    )

                    setTextViewText(R.id.rmind_widget_session_name, sessionName)
                    setViewVisibility(R.id.rmind_widget_session, visibility(sessionRunning))
                    // A Chronometer counts from elapsedRealtime, so the wall
                    // clock start has to be rebased onto that timeline. After
                    // this it ticks inside the launcher with no further
                    // updates from the app.
                    setChronometer(
                        R.id.rmind_widget_session_clock,
                        SystemClock.elapsedRealtime() -
                            (System.currentTimeMillis() - startedAtMs),
                        null,
                        sessionRunning,
                    )

                    // Driven by what is actually on the tile rather than by
                    // the flag alone, so a widget added before the app has
                    // ever pushed still says something instead of showing a
                    // blank box. The pushed wording wins whenever it arrived.
                    if (emptyMessage.isNotEmpty()) {
                        setTextViewText(R.id.rmind_widget_empty, emptyMessage)
                    }
                    setViewVisibility(
                        R.id.rmind_widget_empty,
                        visibility(!hasReminder && !sessionRunning),
                    )
                }

            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    private fun visibility(visible: Boolean): Int = if (visible) View.VISIBLE else View.GONE

    companion object {
        // These must stay identical to the key constants in
        // lib/services/widget_service.dart. Nothing checks them at build time.
        private const val KEY_WHEN = "rmind_when"
        private const val KEY_TITLE = "rmind_title"
        private const val KEY_IS_ALARM = "rmind_is_alarm"
        private const val KEY_SESSION_RUNNING = "rmind_session_running"
        private const val KEY_SESSION_NAME = "rmind_session_name"
        private const val KEY_SESSION_STARTED_MS = "rmind_session_started_ms"
        private const val KEY_EMPTY = "rmind_empty"

        private const val TRUE = "true"
    }
}
