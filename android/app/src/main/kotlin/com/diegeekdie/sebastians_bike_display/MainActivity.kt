package com.diegeekdie.sebastians_bike_display

import android.content.ContentValues
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val exportChannelName = "sebastians_bike_display/file_export"
    private val backgroundNotificationChannelName =
        "sebastians_bike_display/background_notification"
    private val rideTrackingChannelId = "ride_tracking"
    private val rideTrackingChannelName = "Ride Tracking"
    private val rideTrackingNotificationId = 888

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            exportChannelName
        ).setMethodCallHandler { call, result ->
            if (call.method != "saveToDownloads") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            val fileName = call.argument<String>("fileName")
            val mimeType = call.argument<String>("mimeType")
            val bytes = call.argument<ByteArray>("bytes")

            if (fileName.isNullOrBlank() || mimeType.isNullOrBlank() || bytes == null) {
                result.error("invalid_args", "fileName, mimeType and bytes are required.", null)
                return@setMethodCallHandler
            }

            try {
                val path = saveToDownloads(fileName, mimeType, bytes)
                result.success(path)
            } catch (exception: Exception) {
                result.error("save_failed", exception.message, null)
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            backgroundNotificationChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "attachForegroundActionToRideNotification" -> {
                    attachForegroundActionToRideNotification()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun attachForegroundActionToRideNotification() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val existingChannel = manager.getNotificationChannel(rideTrackingChannelId)
            if (existingChannel == null) {
                val channel = NotificationChannel(
                    rideTrackingChannelId,
                    rideTrackingChannelName,
                    NotificationManager.IMPORTANCE_LOW
                )
                manager.createNotificationChannel(channel)
            }
        }

        val launchIntent = Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
        val launchPendingIntent = PendingIntent.getActivity(this, 0, launchIntent, flags)

        val notification = NotificationCompat.Builder(this, rideTrackingChannelId)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Simple Bike Display")
            .setContentText("Ride recording active in background")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(launchPendingIntent)
            .addAction(
                0,
                "Open",
                launchPendingIntent,
            )
            .build()

        manager.notify(rideTrackingNotificationId, notification)
    }

    private fun saveToDownloads(fileName: String, mimeType: String, bytes: ByteArray): String {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            saveWithMediaStore(fileName, mimeType, bytes)
        } else {
            saveWithLegacyExternalStorage(fileName, bytes)
        }
    }

    private fun saveWithMediaStore(fileName: String, mimeType: String, bytes: ByteArray): String {
        val resolver = applicationContext.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, fileName)
            put(MediaStore.Downloads.MIME_TYPE, mimeType)
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }

        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("Unable to create download entry.")

        resolver.openOutputStream(uri)?.use { output ->
            output.write(bytes)
        } ?: throw IllegalStateException("Unable to open download output stream.")

        values.clear()
        values.put(MediaStore.Downloads.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
        return uri.toString()
    }

    private fun saveWithLegacyExternalStorage(fileName: String, bytes: ByteArray): String {
        val downloadsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        if (!downloadsDir.exists()) {
            downloadsDir.mkdirs()
        }
        val file = File(downloadsDir, fileName)
        FileOutputStream(file).use { output ->
            output.write(bytes)
        }
        return file.absolutePath
    }
}
