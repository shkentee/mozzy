package com.example.app_mobile

import android.app.PendingIntent
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Base64
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.zip.CRC32
import org.json.JSONArray
import org.json.JSONObject

private const val WIRED_RESCUE_CHANNEL_ID = "wr_usb_rescue"
private const val WIRED_RESCUE_NOTIFICATION_ID = 1002
private const val FLUTTER_SHARED_PREFS_NAME = "FlutterSharedPreferences"
private const val FLUTTER_PREF_PREFIX = "flutter."
private const val WR_UPLOADED_IDS_KEY = "${FLUTTER_PREF_PREFIX}wr_uploaded_ids"
private const val JSON_LIST_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu!"
private const val USB_PERMISSION_ACTION = "com.example.app_mobile.USB_PERMISSION"
private const val WIRED_RESCUE_TAG = "MozzyUsbRescue"

private object UsbPermissionResult {
    @Volatile private var latch: CountDownLatch? = null
    @Volatile var granted = false
        private set

    @Synchronized
    fun prepare(): CountDownLatch {
        granted = false
        return CountDownLatch(1).also { latch = it }
    }

    fun handle(context: Context, intent: Intent) {
        if (intent.action != USB_PERMISSION_ACTION) return
        val returned = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
        }
        val manager = context.getSystemService(Context.USB_SERVICE) as UsbManager
        granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false) ||
            returned?.let { manager.hasPermission(it) } == true
        latch?.countDown()
    }
}

class UsbPermissionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        UsbPermissionResult.handle(context, intent)
    }
}

private object WiredUsbRescueState {
    @Volatile private var running = false
    @Volatile private var status = "待機中"
    @Volatile private var currentFile: String? = null
    @Volatile private var lastError: String? = null
    @Volatile private var totalFiles = 0
    @Volatile private var queuedFiles = 0
    @Volatile private var totalBytes = 0L
    @Volatile private var processedBytes = 0L

    @Synchronized
    fun reset(message: String) {
        running = true
        status = message
        currentFile = null
        lastError = null
        totalFiles = 0
        queuedFiles = 0
        totalBytes = 0L
        processedBytes = 0L
    }

    @Synchronized
    fun progress(
        message: String,
        current: String? = currentFile,
        totalFileCount: Int = totalFiles,
        queuedFileCount: Int = queuedFiles,
        totalByteCount: Long = totalBytes,
        processedByteCount: Long = processedBytes,
    ) {
        status = message
        currentFile = current
        totalFiles = totalFileCount
        queuedFiles = queuedFileCount
        totalBytes = totalByteCount
        processedBytes = processedByteCount
    }

    @Synchronized
    fun queued(
        message: String,
        current: String,
        processedByteCount: Long,
        newlyQueued: Boolean,
    ) {
        status = message
        currentFile = current
        processedBytes = processedByteCount
        if (newlyQueued) queuedFiles += 1
    }

    @Synchronized
    fun finish(message: String) {
        running = false
        status = message
        currentFile = null
    }

    @Synchronized
    fun fail(message: String) {
        running = false
        status = "USB救出エラー: $message"
        lastError = message
        currentFile = null
    }

    @Synchronized
    fun toMap(): Map<String, Any?> = mapOf(
        "running" to running,
        "status" to status,
        "currentFile" to currentFile,
        "lastError" to lastError,
        "totalFiles" to totalFiles,
        "queuedFiles" to queuedFiles,
        "totalBytes" to totalBytes,
        "processedBytes" to processedBytes,
    )
}

class MainActivity : FlutterActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "mojio/wired_usb"
        ).setMethodCallHandler { call, result ->
            Thread {
                try {
                    Log.i(WIRED_RESCUE_TAG, "method start ${call.method}")
                    val value = when (call.method) {
                        "ping" -> withSession { it.ping() }
                        "pauseRecording" -> withSession { it.pauseRecording() }
                        "resumeRecording" -> withSession { it.resumeRecording() }
                        "listFiles" -> withSession { it.listFiles() }
                        "listRescueCandidates" -> listRescueCandidates()
                        "fetchFile" -> fetchFile(call)
                        "diagnoseUsb" -> diagnoseUsb()
                        "setKeepScreenOn" -> setKeepScreenOn(call)
                        "startQueueAll" -> startWiredRescue(null)
                        "startQueueOne" -> startWiredRescue(call.argument<String>("name"))
                        "getRescueStatus" -> WiredUsbRescueState.toMap()
                        else -> throw IllegalArgumentException("Unknown method ${call.method}")
                    }
                    Log.i(WIRED_RESCUE_TAG, "method ok ${call.method}")
                    mainHandler.post { result.success(value) }
                } catch (e: WiredUsbException) {
                    Log.e(WIRED_RESCUE_TAG, "method failed ${call.method}", e)
                    mainHandler.post { result.error(e.code, e.message, null) }
                } catch (e: Exception) {
                    Log.e(WIRED_RESCUE_TAG, "method error ${call.method}", e)
                    mainHandler.post {
                        result.error("wired_error", e.message ?: e.toString(), null)
                    }
                }
            }.start()
        }
    }

    private fun fetchFile(call: MethodCall): Long {
        val name = call.argument<String>("name")
            ?: throw WiredUsbException("bad_args", "Missing file name.")
        val path = call.argument<String>("path")
            ?: throw WiredUsbException("bad_args", "Missing destination path.")
        return withSession { it.fetchFile(name, File(path)) }
    }

    private fun setKeepScreenOn(call: MethodCall): Boolean {
        val enabled = call.argument<Boolean>("enabled") ?: false
        val latch = CountDownLatch(1)
        mainHandler.post {
            if (enabled) {
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
            latch.countDown()
        }
        latch.await(5, TimeUnit.SECONDS)
        return enabled
    }

    private fun listRescueCandidates(): List<Map<String, Any>> {
        var lastTimeout: WiredUsbException? = null
        repeat(2) { attempt ->
            try {
                return withSession { session ->
                    session.listFiles().filter { raw ->
                        val name = raw["name"] as? String ?: return@filter false
                        val size = raw["size"] as? Long ?: (raw["size"] as? Int)?.toLong() ?: 0L
                        !isAlreadyRescuedByAppState(this, WiredNativeFile(name, size))
                    }
                }
            } catch (e: WiredUsbException) {
                if (e.code != "wired_timeout" || attempt > 0) {
                    throw e
                }
                lastTimeout = e
                Log.w(WIRED_RESCUE_TAG, "list timed out; reopening USB session once", e)
                Thread.sleep(500)
            }
        }
        throw lastTimeout ?: WiredUsbException("wired_timeout", "Timed out while listing USB files.")
    }

    private fun startWiredRescue(name: String?): Boolean {
        val manager = getSystemService(Context.USB_SERVICE) as UsbManager
        requirePermittedUsbDevice(manager)

        val intent = Intent(this, WiredUsbRescueService::class.java).apply {
            action = WiredUsbRescueService.ACTION_START
            if (!name.isNullOrBlank()) {
                putExtra(WiredUsbRescueService.EXTRA_NAME, name)
            }
        }
        if (Build.VERSION.SDK_INT >= 26) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
        return true
    }

    private fun <T> withSession(block: (CdcSession) -> T): T {
        val manager = getSystemService(Context.USB_SERVICE) as UsbManager
        val device = requirePermittedUsbDevice(manager)

        val opened = manager.openDevice(device)
            ?: throw WiredUsbException("usb_open_failed", "Could not open USB device.")
        val session = CdcSession(device, opened)
        return try {
            session.open()
            block(session)
        } finally {
            session.close()
        }
    }

    private fun requirePermittedUsbDevice(manager: UsbManager): UsbDevice {
        val device = manager.deviceList.values.firstOrNull { CdcSession.canUse(it) }
            ?: throw WiredUsbException(
                "no_usb_device",
                "Mozzy USB device was not found.\n${usbDiagnostics(manager)}"
            )
        if (manager.hasPermission(device)) {
            return device
        }

        requestUsbPermission(manager, device)
        return waitForPermittedCdcDevice(manager)
            ?: throw WiredUsbException("usb_permission", "USB permission was not granted.")
    }

    private fun waitForPermittedCdcDevice(manager: UsbManager): UsbDevice? {
        repeat(100) {
            val permitted = manager.deviceList.values.firstOrNull {
                CdcSession.canUse(it) && manager.hasPermission(it)
            }
            if (permitted != null) return permitted
            Thread.sleep(100)
        }
        return manager.deviceList.values.firstOrNull {
            CdcSession.canUse(it) && manager.hasPermission(it)
        }
    }

    private fun diagnoseUsb(): String {
        val manager = getSystemService(Context.USB_SERVICE) as UsbManager
        return usbDiagnostics(manager)
    }

    private fun usbDiagnostics(manager: UsbManager): String {
        val devices = manager.deviceList.values.toList()
        if (devices.isEmpty()) {
            return "Androidから見えるUSB機器はありません。スマホがUSBホストになっていない、ケーブルが充電専用、またはデバイス側USBが起動していない可能性があります。"
        }

        return buildString {
            append("Androidから見えるUSB機器: ${devices.size}件")
            devices.forEachIndexed { index, device ->
                append("\n")
                append(index + 1)
                append(". VID=")
                append("%04X".format(device.vendorId))
                append(" PID=")
                append("%04X".format(device.productId))
                append(" class=")
                append(device.deviceClass)
                append(" ifaces=")
                append(device.interfaceCount)
                append(" cdc=")
                append(CdcSession.canUse(device))
                for (i in 0 until device.interfaceCount) {
                    val iface = device.getInterface(i)
                    append("\n   iface ")
                    append(i)
                    append(": class=")
                    append(iface.interfaceClass)
                    append(" subclass=")
                    append(iface.interfaceSubclass)
                    append(" endpoints=")
                    append(iface.endpointCount)
                }
            }
        }
    }

    private fun requestUsbPermission(manager: UsbManager, device: UsbDevice): Boolean {
        val latch = UsbPermissionResult.prepare()
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
        val permissionIntent = Intent(USB_PERMISSION_ACTION).apply {
            setClass(this@MainActivity, UsbPermissionReceiver::class.java)
        }
        val intent = PendingIntent.getBroadcast(this, 0, permissionIntent, flags)
        manager.requestPermission(device, intent)
        val broadcastGranted = latch.await(30, TimeUnit.SECONDS) && UsbPermissionResult.granted
        return if (broadcastGranted) {
            true
        } else {
            waitForUsbPermission(manager, device) || waitForPermittedCdcDevice(manager) != null
        }
    }

    private fun waitForUsbPermission(manager: UsbManager, device: UsbDevice): Boolean {
        repeat(20) {
            if (manager.hasPermission(device)) return true
            Thread.sleep(100)
        }
        return manager.hasPermission(device)
    }
}

class WiredUsbRescueService : Service() {
    companion object {
        const val ACTION_START = "com.example.app_mobile.action.WIRED_RESCUE_START"
        const val EXTRA_NAME = "name"

        @Volatile private var workerRunning = false
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureNotificationChannel()
        startRescueForeground("USB救出を準備中")

        if (workerRunning) {
            updateNotification("USB救出は実行中です")
            return START_NOT_STICKY
        }

        val singleName = intent?.getStringExtra(EXTRA_NAME)
        workerRunning = true
        Thread {
            runRescue(singleName)
        }.start()
        return START_NOT_STICKY
    }

    private fun runRescue(singleName: String?) {
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        val wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "$packageName:WiredUsbRescue"
        )
        wakeLock.acquire(6 * 60 * 60 * 1000L)
        WiredUsbRescueState.reset("USB救出を開始します...")

        var session: CdcSession? = null
        try {
            val manager = getSystemService(Context.USB_SERVICE) as UsbManager
            val device = manager.deviceList.values.firstOrNull { CdcSession.canUse(it) }
                ?: throw WiredUsbException(
                    "no_usb_device",
                    "Mozzy USB device was not found."
                )
            Log.i(WIRED_RESCUE_TAG, "start singleName=$singleName device=${device.deviceName} permission=${manager.hasPermission(device)}")
            if (!manager.hasPermission(device)) {
                throw WiredUsbException("usb_permission", "USB permission was not granted.")
            }

            fun reopenSession(): CdcSession {
                session?.close()
                val opened = manager.openDevice(device)
                    ?: throw WiredUsbException("usb_open_failed", "Could not open USB device.")
                return CdcSession(device, opened).also {
                    session = it
                    it.open()
                    progress("録音を一時停止中...")
                    it.pauseRecording()
                }
            }

            val initialSession = reopenSession()
            var successMessage: String? = null
            try {
                progress("USB内の録音を確認中...")
                val listedFiles = initialSession.listFiles().mapNotNull { raw ->
                    val name = raw["name"] as? String ?: return@mapNotNull null
                    val size = raw["size"] as? Long ?: (raw["size"] as? Int)?.toLong() ?: 0L
                    if (singleName == null || name == singleName) {
                        WiredNativeFile(name, size)
                    } else {
                        null
                    }
                }
                val alreadyRescued = listedFiles.associateWith {
                    isAlreadyRescuedByAppState(this, it)
                }
                val skippedFiles = alreadyRescued.count { it.value }
                val allFiles = listedFiles.filterNot { alreadyRescued[it] == true }
                val totalBytes = allFiles.sumOf { it.sizeBytes }
                Log.i(
                    WIRED_RESCUE_TAG,
                    "listed=${listedFiles.map { "${it.name}:${it.sizeBytes}" }} skipped=$skippedFiles targets=${allFiles.map { "${it.name}:${it.sizeBytes}" }}"
                )
                WiredUsbRescueState.progress(
                    if (allFiles.isEmpty()) {
                        if (skippedFiles > 0) {
                            "USB救出対象なし: ${skippedFiles}件は救出済みです"
                        } else {
                            "USB側に吸出し対象ファイルはありません"
                        }
                    } else if (skippedFiles > 0) {
                        "USB吸出し中...（${skippedFiles}件は救出済みのためスキップ）"
                    } else {
                        "USB吸出し中..."
                    },
                    totalFileCount = allFiles.size,
                    totalByteCount = totalBytes,
                )

                var completedBytes = 0L
                val failedFiles = mutableListOf<String>()
                val maxAttempts = 3
                for (file in allFiles) {
                    var attempt = 1
                    var rescued = false
                    while (attempt <= maxAttempts && !rescued) {
                        Log.i(WIRED_RESCUE_TAG, "fetch start ${file.name} size=${file.sizeBytes} attempt=$attempt/$maxAttempts")
                        val attemptLabel = if (attempt == 1) {
                            "USB吸出し中: ${file.name}"
                        } else {
                            "USB吸出し再試行中: ${file.name} (${attempt}/${maxAttempts})"
                        }
                        progress(attemptLabel, current = file.name)
                        val legacyTemp = File(cacheDir, file.name)
                        val part = File(cacheDir, "${file.name}.part")
                        if (legacyTemp.exists()) {
                            if (!part.exists()) {
                                legacyTemp.renameTo(part)
                            } else {
                                legacyTemp.delete()
                            }
                        }
                        if (file.sizeBytes > 0 && part.exists() && part.length() > file.sizeBytes) {
                            part.delete()
                        }
                        var lastNotificationAt = 0L
                        try {
                            val activeSession = session ?: reopenSession()
                            val resumeFrom = if (part.exists()) part.length() else 0L
                            val received = if (file.sizeBytes > 0 && resumeFrom >= file.sizeBytes) {
                                Log.i(WIRED_RESCUE_TAG, "resume part already complete ${file.name} bytes=$resumeFrom")
                                resumeFrom
                            } else {
                                activeSession.fetchFile(file.name, part, resumeFrom) { written ->
                                    val processed = completedBytes + written
                                    WiredUsbRescueState.progress(
                                        attemptLabel,
                                        current = file.name,
                                        processedByteCount = processed,
                                    )
                                    val now = System.currentTimeMillis()
                                    if (now - lastNotificationAt >= 2000L ||
                                        (file.sizeBytes > 0 && written >= file.sizeBytes)
                                    ) {
                                        lastNotificationAt = now
                                        updateNotification(attemptLabel)
                                    }
                                }
                            }
                            if (file.sizeBytes > 0 && received != file.sizeBytes) {
                                throw WiredUsbException(
                                    "wired_size_mismatch",
                                    "Expected ${file.sizeBytes} bytes but received $received bytes."
                                )
                            }
                            completedBytes += received
                            Log.i(WIRED_RESCUE_TAG, "fetch done ${file.name} received=$received partLength=${part.length()} attempt=$attempt/$maxAttempts")
                            val queued = enqueueToOutbox(part, file.name)
                            Log.i(WIRED_RESCUE_TAG, "queued ${queued.name} bytes=${queued.sizeBytes} newlyQueued=${queued.newlyQueued}")
                            WiredUsbRescueState.queued(
                                if (queued.newlyQueued) {
                                    "送信待ちへ追加: ${queued.name}"
                                } else {
                                    "送信待ちに登録済み: ${queued.name}"
                                },
                                queued.name,
                                completedBytes,
                                queued.newlyQueued,
                            )
                            updateNotification(WiredUsbRescueState.toMap()["status"] as? String ?: "USB救出中")
                            rescued = true
                        } catch (e: Exception) {
                            try {
                                session?.cancelTransfer()
                            } catch (_: Exception) {
                            }
                            Log.w(
                                WIRED_RESCUE_TAG,
                                "fetch failed ${file.name} attempt=$attempt/$maxAttempts",
                                e
                            )
                            WiredUsbRescueState.progress(
                                "USB吸出し失敗: ${file.name} (${attempt}/${maxAttempts})",
                                current = file.name,
                                processedByteCount = completedBytes,
                            )
                            updateNotification("USB吸出し再試行待ち: ${file.name}")
                            val canRetry = e !is WiredUsbException ||
                                e.code == "wired_timeout" ||
                                e.code == "usb_write_failed" ||
                                e.code == "usb_closed" ||
                                e.code == "usb_open_failed"
                            if (attempt < maxAttempts && canRetry) {
                                Thread.sleep(500L)
                                session = reopenSession()
                            } else {
                                failedFiles.add(file.name)
                                Log.w(WIRED_RESCUE_TAG, "skip after retries ${file.name}")
                                WiredUsbRescueState.progress(
                                    "USB吸出しを後回し: ${file.name}",
                                    current = file.name,
                                    processedByteCount = completedBytes,
                                )
                            }
                            attempt = if (canRetry) attempt + 1 else maxAttempts + 1
                        }
                    }
                }

                val map = WiredUsbRescueState.toMap()
                val queuedFiles = map["queuedFiles"] as? Int ?: 0
                val totalFiles = map["totalFiles"] as? Int ?: 0
                successMessage = if (totalFiles == 0) {
                    "USB救出完了: 対象ファイルはありません"
                } else if (failedFiles.isNotEmpty() && queuedFiles == 0) {
                    "USB救出完了: 今回は追加なし（${failedFiles.size}件は次回再試行）"
                } else if (failedFiles.isNotEmpty()) {
                    "USB救出完了: ${queuedFiles}件を送信待ちに入れました（${failedFiles.size}件は次回再試行）"
                } else if (queuedFiles == 0) {
                    "USB救出完了: すべて送信待ちに登録済みです"
                } else {
                    "USB救出完了: ${queuedFiles}件を送信待ちに入れました"
                }
            } finally {
                try {
                    progress("録音を再開中...")
                    session?.resumeRecording()
                } catch (_: Exception) {
                }
            }
            successMessage?.let { WiredUsbRescueState.finish(it) }
            updateNotification(WiredUsbRescueState.toMap()["status"] as? String ?: "USB救出完了")
        } catch (e: Exception) {
            Log.e(WIRED_RESCUE_TAG, "USB rescue failed", e)
            WiredUsbRescueState.fail(e.message ?: e.toString())
            updateNotification(WiredUsbRescueState.toMap()["status"] as? String ?: "USB救出エラー")
        } finally {
            Log.i(WIRED_RESCUE_TAG, "finish status=${WiredUsbRescueState.toMap()}")
            session?.close()
            if (wakeLock.isHeld) wakeLock.release()
            workerRunning = false
            stopForegroundCompat()
            stopSelf()
        }
    }

    private fun progress(message: String, current: String? = null) {
        WiredUsbRescueState.progress(message, current = current)
        updateNotification(message)
    }

    private fun enqueueToOutbox(source: File, desiredName: String): QueuedNativeFile {
        val safeName = safeWiredFileName(desiredName)
        val outbox = File(filesDir, "outbox")
        outbox.mkdirs()
        val sourceLength = source.length()
        var target = File(outbox, safeName)
        var queueName = safeName

        if (target.exists()) {
            val existingLength = target.length()
            if (existingLength == sourceLength) {
                source.delete()
                writeTimelineSidecar(target, queueName, desiredName, sourceLength)
                return QueuedNativeFile(queueName, existingLength, newlyQueued = false)
            }

            val dot = safeName.lastIndexOf('.')
            val base = if (dot > 0) safeName.substring(0, dot) else safeName
            val ext = if (dot > 0) safeName.substring(dot) else ""
            queueName = "${base}_usb_${System.currentTimeMillis()}$ext"
            target = File(outbox, queueName)
        }

        val tmp = File(target.absolutePath + ".tmp")
        if (tmp.exists()) tmp.delete()
        source.copyTo(tmp, overwrite = true)
        if (target.exists()) target.delete()
        if (!tmp.renameTo(target)) {
            throw WiredUsbException("queue_failed", "Could not move ${source.name} into outbox.")
        }
        source.delete()
        writeTimelineSidecar(target, queueName, desiredName, target.length())
        return QueuedNativeFile(queueName, target.length(), newlyQueued = true)
    }

    private fun writeTimelineSidecar(
        audioFile: File,
        queueName: String,
        originalName: String,
        sizeBytes: Long,
    ) {
        val epoch = epochFromAudioName(queueName) ?: epochFromAudioName(originalName)
        if (epoch == null) return
        val payload = JSONObject()
            .put("schema", "mozzy.timeline.v1")
            .put("audio_file", queueName)
            .put("original_file", originalName)
            .put("size_bytes", sizeBytes)
            .put("recording_start_epoch", epoch)
            .put("recording_start_source", "usb_epoch_filename")
            .put("created_at_epoch", System.currentTimeMillis() / 1000L)
        File(audioFile.absolutePath + ".meta.json").writeText(payload.toString())
    }

    private fun epochFromAudioName(name: String): Long? {
        val match = Regex("""^(\d{10})\.opus_sd$""").find(name) ?: return null
        return match.groupValues[1].toLongOrNull()
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            WIRED_RESCUE_CHANNEL_ID,
            "USB救出",
            NotificationManager.IMPORTANCE_LOW
        )
        manager.createNotificationChannel(channel)
    }

    private fun startRescueForeground(text: String) {
        val notification = buildNotification(text)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(
                WIRED_RESCUE_NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            )
        } else {
            startForeground(WIRED_RESCUE_NOTIFICATION_ID, notification)
        }
    }

    private fun updateNotification(text: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(WIRED_RESCUE_NOTIFICATION_ID, buildNotification(text))
    }

    private fun buildNotification(text: String): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, WIRED_RESCUE_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val icon = if (applicationInfo.icon != 0) {
            applicationInfo.icon
        } else {
            android.R.drawable.stat_sys_upload
        }
        return builder
            .setSmallIcon(icon)
            .setContentTitle("Mozzy USB救出")
            .setContentText(text)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .build()
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }
}

private data class WiredNativeFile(val name: String, val sizeBytes: Long)

private data class QueuedNativeFile(
    val name: String,
    val sizeBytes: Long,
    val newlyQueued: Boolean,
)

private fun isAlreadyRescuedByAppState(context: Context, file: WiredNativeFile): Boolean {
    val safeName = safeWiredFileName(file.name)
    val prefs = context.getSharedPreferences(FLUTTER_SHARED_PREFS_NAME, Context.MODE_PRIVATE)
    if (prefs.getBoolean("${FLUTTER_PREF_PREFIX}wr_sync_done_$safeName", false)) {
        return true
    }
    if (uploadedIds(prefs).any { it == "$safeName:${file.sizeBytes}" || it.startsWith("$safeName:") }) {
        return true
    }
    val outboxFile = File(File(context.filesDir, "outbox"), safeName)
    return outboxFile.exists() && outboxFile.length() > 0
}

private fun uploadedIds(prefs: android.content.SharedPreferences): Set<String> {
    val encoded = prefs.getString(WR_UPLOADED_IDS_KEY, null) ?: return emptySet()
    if (!encoded.startsWith(JSON_LIST_PREFIX)) return emptySet()
    return try {
        val items = JSONArray(encoded.substring(JSON_LIST_PREFIX.length))
        buildSet {
            for (i in 0 until items.length()) {
                add(items.getString(i))
            }
        }
    } catch (_: Exception) {
        emptySet()
    }
}

private fun safeWiredFileName(name: String): String {
    val normalized = name.trim().replace('\\', '/')
    val base = normalized.substringAfterLast('/')
    if (base.isBlank() || base == "." || base == "..") {
        throw WiredUsbException("bad_name", "Invalid outbox file name.")
    }
    return base
}

private class WiredUsbException(val code: String, message: String) : Exception(message)

private class CdcSession(
    private val device: UsbDevice,
    private val connection: UsbDeviceConnection,
) {
    private var controlInterface: UsbInterface? = null
    private var dataInterface: UsbInterface? = null
    private var inEndpoint: UsbEndpoint? = null
    private var outEndpoint: UsbEndpoint? = null
    private val readBuffer = ByteArray(64 * 1024)
    private var readPos = 0
    private var readLen = 0
    private var lineControlIndex = -1

    fun open() {
        for (i in 0 until device.interfaceCount) {
            val iface = device.getInterface(i)
            if (iface.interfaceClass == UsbConstants.USB_CLASS_COMM) {
                controlInterface = iface
            }
            if (iface.interfaceClass == UsbConstants.USB_CLASS_CDC_DATA) {
                dataInterface = iface
                for (e in 0 until iface.endpointCount) {
                    val ep = iface.getEndpoint(e)
                    if (ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK) {
                        if (ep.direction == UsbConstants.USB_DIR_IN) {
                            inEndpoint = ep
                        } else if (ep.direction == UsbConstants.USB_DIR_OUT) {
                            outEndpoint = ep
                        }
                    }
                }
            }
        }
        val data = dataInterface
            ?: throw WiredUsbException("usb_no_cdc", "CDC data interface was not found.")
        val inEp = inEndpoint
            ?: throw WiredUsbException("usb_no_cdc", "CDC bulk-in endpoint was not found.")
        val outEp = outEndpoint
            ?: throw WiredUsbException("usb_no_cdc", "CDC bulk-out endpoint was not found.")

        controlInterface?.let { connection.claimInterface(it, true) }
        if (!connection.claimInterface(data, true)) {
            throw WiredUsbException("usb_claim_failed", "Could not claim USB CDC interface.")
        }

        val controlIndex = controlInterface?.id ?: data.id
        lineControlIndex = controlIndex
        val lineCoding = byteArrayOf(
            0x00, 0xC2.toByte(), 0x01, 0x00, // 115,200 baud
            0x00, // 1 stop bit
            0x00, // no parity
            0x08, // 8 data bits
        )
        connection.controlTransfer(0x21, 0x20, 0, controlIndex, lineCoding, lineCoding.size, 1000)
        connection.controlTransfer(0x21, 0x22, 0x03, controlIndex, null, 0, 1000)

        inEndpoint = inEp
        outEndpoint = outEp
        recoverProtocolOnOpen()
    }

    fun close() {
        try {
            cancelTransfer()
        } catch (_: Exception) {
        }
        if (lineControlIndex >= 0) {
            try {
                connection.controlTransfer(0x21, 0x22, 0x00, lineControlIndex, null, 0, 500)
            } catch (_: Exception) {
            }
        }
        dataInterface?.let { connection.releaseInterface(it) }
        controlInterface?.let { connection.releaseInterface(it) }
        connection.close()
    }

    fun cancelTransfer() {
        val out = outEndpoint ?: return
        val cancel = byteArrayOf(0x03)
        connection.bulkTransfer(out, cancel, cancel.size, 250)
    }

    fun ping(): String {
        writeLine("wr-ping")
        val line = readUntilPrefix("WR-OK ", 5000)
        return line.removePrefix("WR-OK ").trim()
    }

    fun pauseRecording(): String {
        writeLine("wr-pause")
        val line = readUntilPrefix("WR-", 8000)
        if (line.startsWith("WR-ERR")) throw WiredUsbException("wired_protocol", line)
        return line.removePrefix("WR-OK ").trim()
    }

    fun resumeRecording(): String {
        writeLine("wr-resume")
        val line = readUntilPrefix("WR-", 8000)
        if (line.startsWith("WR-ERR")) throw WiredUsbException("wired_protocol", line)
        return line.removePrefix("WR-OK ").trim()
    }

    fun listFiles(): List<Map<String, Any>> {
        writeLine("wr-list")
        readUntilPrefix("WR-LIST-BEGIN", 10000)
        val files = mutableListOf<Map<String, Any>>()
        while (true) {
            val line = readLine(15000)
            when {
                line.startsWith("WR-FILE ") -> {
                    val rest = line.removePrefix("WR-FILE ")
                    val split = rest.lastIndexOf(' ')
                    if (split > 0) {
                        val name = rest.substring(0, split)
                        val size = rest.substring(split + 1).toLongOrNull() ?: 0L
                        files.add(mapOf("name" to name, "size" to size))
                    }
                }
                line.startsWith("WR-END") -> return files
                line.startsWith("WR-ERR") -> throw WiredUsbException("wired_protocol", line)
            }
        }
    }

    fun fetchFile(
        name: String,
        destination: File,
        resumeFrom: Long = 0L,
        onProgress: ((Long) -> Unit)? = null,
    ): Long {
        requireSafeName(name)
        destination.parentFile?.mkdirs()
        writeLine(if (resumeFrom > 0L) "wr-fetch $name $resumeFrom" else "wr-fetch $name")
        val begin = readUntilPrefix("WR-FETCH-BEGIN ", 15000)
        val header = parseFetchBegin(begin)
        if (header.startOffset != resumeFrom) {
            throw WiredUsbException(
                "wired_resume_mismatch",
                "Device started at ${header.startOffset} but expected $resumeFrom."
            )
        }
        if (!header.binaryCrc32) {
            if (resumeFrom > 0L) {
                throw WiredUsbException(
                    "wired_resume_unsupported",
                    "Device does not support resumable binary transfer."
                )
            }
            return fetchFileBase64(destination, onProgress)
        }

        var written = resumeFrom
        FileOutputStream(destination, resumeFrom > 0L).use { out ->
            while (written < header.sizeBytes) {
                val line = readUntilPrefix("WR-", 30000)
                when {
                    line.startsWith("WR-DATA2 ") -> {
                        val chunk = parseStreamChunkHeader(line)
                        if (chunk.offset < 4096L || chunk.offset % (1024L * 1024L) == 0L) {
                            Log.i(
                                WIRED_RESCUE_TAG,
                                "stream chunk offset=${chunk.offset} length=${chunk.length}"
                            )
                        }
                        if (chunk.length <= 0 ||
                            chunk.length > 1024 * 1024 ||
                            written + chunk.length > header.sizeBytes
                        ) {
                            throw WiredUsbException(
                                "wired_chunk_size",
                                "Invalid USB stream chunk length ${chunk.length}."
                            )
                        }
                        if (chunk.offset != written) {
                            readExactBytes(chunk.length, 60000)
                            discardFetchRemainder()
                            throw WiredUsbException(
                                "wired_offset_mismatch",
                                "Device sent offset ${chunk.offset} but expected $written."
                            )
                        }
                        val bytes = readExactBytes(chunk.length, 60000)
                        val crcLine = readUntilPrefix("WR-CRC ", 30000)
                        val reported = parseStreamCrc(crcLine)
                        if (reported.offset != chunk.offset || reported.length != chunk.length) {
                            discardFetchRemainder()
                            throw WiredUsbException(
                                "wired_crc_mismatch",
                                "USB stream CRC metadata mismatch at offset ${chunk.offset}."
                            )
                        }
                        val crc = CRC32()
                        crc.update(bytes)
                        if (crc.value != reported.crc32) {
                            discardFetchRemainder()
                            throw WiredUsbException(
                                "wired_crc_mismatch",
                                "USB stream CRC mismatch at offset ${chunk.offset}."
                            )
                        }
                        out.write(bytes)
                        written += bytes.size.toLong()
                        onProgress?.invoke(written)
                    }
                    line.startsWith("WR-DATA ") -> {
                        val chunk = parseBinaryChunkHeader(line)
                        if (chunk.offset < 4096L || chunk.offset % (1024L * 1024L) == 0L) {
                            Log.i(
                                WIRED_RESCUE_TAG,
                                "binary chunk offset=${chunk.offset} length=${chunk.length}"
                            )
                        }
                        if (chunk.length < 0 ||
                            chunk.length > 1024 * 1024 ||
                            written + chunk.length > header.sizeBytes
                        ) {
                            throw WiredUsbException(
                                "wired_chunk_size",
                                "Invalid USB chunk length ${chunk.length}."
                            )
                        }
                        if (chunk.offset != written) {
                            readExactBytes(chunk.length, 30000)
                            discardFetchRemainder()
                            throw WiredUsbException(
                                "wired_offset_mismatch",
                                "Device sent offset ${chunk.offset} but expected $written."
                            )
                        }
                        val bytes = readExactBytes(chunk.length, 30000)
                        val crc = CRC32()
                        crc.update(bytes)
                        if (crc.value != chunk.crc32) {
                            discardFetchRemainder()
                            throw WiredUsbException(
                                "wired_crc_mismatch",
                                "USB chunk CRC mismatch at offset ${chunk.offset}."
                            )
                        }
                        out.write(bytes)
                        written += bytes.size.toLong()
                        onProgress?.invoke(written)
                    }
                    line.startsWith("WR-ERR") -> throw WiredUsbException("wired_protocol", line)
                }
            }
            out.fd.sync()
        }

        val end = readUntilPrefix("WR-END", 30000)
        val sent = end.removePrefix("WR-END").trim().toLongOrNull()
        if (sent != null && sent != written) {
            throw WiredUsbException(
                "wired_size_mismatch",
                "Device reported $sent bytes but received $written bytes."
            )
        }
        return written
    }

    private fun discardFetchRemainder() {
        try {
            while (true) {
                val line = readUntilPrefix("WR-", 30000)
                when {
                    line.startsWith("WR-DATA2 ") -> {
                        val chunk = parseStreamChunkHeader(line)
                        if (chunk.length < 0 || chunk.length > 1024 * 1024) return
                        readExactBytes(chunk.length, 60000)
                    }
                    line.startsWith("WR-DATA ") -> {
                        val chunk = parseBinaryChunkHeader(line)
                        if (chunk.length < 0 || chunk.length > 1024 * 1024) return
                        readExactBytes(chunk.length, 30000)
                    }
                    line.startsWith("WR-CRC ") -> Unit
                    line.startsWith("WR-END") -> return
                    line.startsWith("WR-ERR") -> return
                }
            }
        } catch (e: Exception) {
            Log.w(WIRED_RESCUE_TAG, "discard fetch remainder failed", e)
        }
    }

    private fun fetchFileBase64(
        destination: File,
        onProgress: ((Long) -> Unit)? = null,
    ): Long {
        var written = 0L
        FileOutputStream(destination).use { out ->
            while (true) {
                val line = readLine(30000)
                var tokenIndex = nextProtocolToken(line, 0)
                while (tokenIndex >= 0) {
                    when {
                        line.startsWith("WR-DATA ", tokenIndex) -> {
                            val payloadStart = tokenIndex + "WR-DATA ".length
                            val next = nextProtocolToken(line, payloadStart)
                            val payload = if (next >= 0) {
                                line.substring(payloadStart, next)
                            } else {
                                line.substring(payloadStart)
                            }.trim()
                            val bytes = decodeWiredBase64(payload)
                            out.write(bytes)
                            written += bytes.size.toLong()
                            onProgress?.invoke(written)
                            tokenIndex = next
                        }
                        line.startsWith("WR-END", tokenIndex) -> {
                        out.fd.sync()
                            val next = nextProtocolToken(line, tokenIndex + "WR-END".length)
                            val payload = if (next >= 0) {
                                line.substring(tokenIndex + "WR-END".length, next)
                            } else {
                                line.substring(tokenIndex + "WR-END".length)
                            }.trim()
                            val sent = payload.toLongOrNull()
                        if (sent != null && sent != written) {
                            throw WiredUsbException(
                                "wired_size_mismatch",
                                "Device reported $sent bytes but received $written bytes."
                            )
                        }
                        return written
                    }
                        line.startsWith("WR-ERR", tokenIndex) -> throw WiredUsbException(
                        "wired_protocol",
                            line.substring(tokenIndex)
                    )
                        else -> tokenIndex = nextProtocolToken(line, tokenIndex + 1)
                    }
                }
            }
        }
    }

    private data class FetchBegin(
        val sizeBytes: Long,
        val binaryCrc32: Boolean,
        val binaryStreamCrc32: Boolean,
        val startOffset: Long,
    )

    private data class BinaryChunkHeader(
        val offset: Long,
        val length: Int,
        val crc32: Long,
    )

    private data class StreamChunkHeader(
        val offset: Long,
        val length: Int,
    )

    private fun parseFetchBegin(line: String): FetchBegin {
        val parts = line.removePrefix("WR-FETCH-BEGIN ")
            .trim()
            .split(Regex("\\s+"))
        val size = parts.getOrNull(1)?.toLongOrNull() ?: 0L
        val mode = parts.getOrNull(2)
        return FetchBegin(
            sizeBytes = size,
            binaryCrc32 = mode == "binary-crc32" || mode == "binary-stream-crc32",
            binaryStreamCrc32 = mode == "binary-stream-crc32",
            startOffset = parts.getOrNull(3)?.toLongOrNull() ?: 0L,
        )
    }

    private fun parseBinaryChunkHeader(line: String): BinaryChunkHeader {
        val parts = line.removePrefix("WR-DATA ")
            .trim()
            .split(Regex("\\s+"))
        val offset = parts.getOrNull(0)?.toLongOrNull()
        val length = parts.getOrNull(1)?.toIntOrNull()
        val crc = parts.getOrNull(2)?.toLongOrNull(16)
        if (offset == null || length == null || crc == null) {
            throw WiredUsbException("wired_protocol", "Bad binary chunk header: $line")
        }
        return BinaryChunkHeader(offset, length, crc)
    }

    private fun parseStreamChunkHeader(line: String): StreamChunkHeader {
        val parts = line.removePrefix("WR-DATA2 ")
            .trim()
            .split(Regex("\\s+"))
        val offset = parts.getOrNull(0)?.toLongOrNull()
        val length = parts.getOrNull(1)?.toIntOrNull()
        if (offset == null || length == null) {
            throw WiredUsbException("wired_protocol", "Bad stream chunk header: $line")
        }
        return StreamChunkHeader(offset, length)
    }

    private fun parseStreamCrc(line: String): BinaryChunkHeader {
        val parts = line.removePrefix("WR-CRC ")
            .trim()
            .split(Regex("\\s+"))
        val offset = parts.getOrNull(0)?.toLongOrNull()
        val length = parts.getOrNull(1)?.toIntOrNull()
        val crc = parts.getOrNull(2)?.toLongOrNull(16)
        if (offset == null || length == null || crc == null) {
            throw WiredUsbException("wired_protocol", "Bad stream CRC line: $line")
        }
        return BinaryChunkHeader(offset, length, crc)
    }

    private fun nextProtocolToken(line: String, startIndex: Int): Int {
        val data = line.indexOf("WR-DATA ", startIndex)
        val end = line.indexOf("WR-END", startIndex)
        val error = line.indexOf("WR-ERR", startIndex)
        return listOf(data, end, error).filter { it >= 0 }.minOrNull() ?: -1
    }

    private fun decodeWiredBase64(raw: String): ByteArray {
        val trimmed = raw.trim()
        val base64Prefix = trimmed.takeWhile {
            it in 'A'..'Z' ||
                it in 'a'..'z' ||
                it in '0'..'9' ||
                it == '+' ||
                it == '/' ||
                it == '='
        }
        val usableLength = base64Prefix.length - (base64Prefix.length % 4)
        if (usableLength <= 0) {
            throw WiredUsbException(
                "wired_bad_base64",
                "Bad base64 payload near '${trimmed.take(48)}'"
            )
        }
        val payload = base64Prefix.substring(0, usableLength)
        return try {
            Base64.decode(payload, Base64.DEFAULT)
        } catch (e: IllegalArgumentException) {
            throw WiredUsbException(
                "wired_bad_base64",
                "Bad base64 payload near '${trimmed.take(48)}'"
            )
        }
    }

    private fun requireSafeName(name: String) {
        if (!name.endsWith(".opus_sd") ||
            name.contains('/') ||
            name.contains('\\') ||
            name.contains(':') ||
            name.isBlank()
        ) {
            throw WiredUsbException("bad_name", "Unsafe file name.")
        }
    }

    private fun writeLine(line: String) {
        val bytes = "$line\n".toByteArray(StandardCharsets.US_ASCII)
        var offset = 0
        val out = outEndpoint ?: throw WiredUsbException("usb_closed", "USB session is closed.")
        while (offset < bytes.size) {
            val n = connection.bulkTransfer(out, bytes, offset, bytes.size - offset, 5000)
            if (n <= 0) {
                throw WiredUsbException("usb_write_failed", "USB write failed.")
            }
            offset += n
        }
    }

    private fun readUntilPrefix(prefix: String, timeoutMs: Long): String {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            val line = readLine(deadline - System.currentTimeMillis())
            if (line.startsWith(prefix)) return line
            val embeddedPrefix = line.indexOf(prefix)
            if (embeddedPrefix > 0) {
                return line.substring(embeddedPrefix)
            }
            if (line.startsWith("WR-ERR")) {
                throw WiredUsbException("wired_protocol", line)
            }
            val embeddedError = line.indexOf("WR-ERR")
            if (embeddedError > 0) {
                throw WiredUsbException("wired_protocol", line.substring(embeddedError))
            }
        }
        throw WiredUsbException("wired_timeout", "Timed out waiting for $prefix.")
    }

    private fun readLine(timeoutMs: Long): String {
        val out = StringBuilder()
        val deadline = System.currentTimeMillis() + timeoutMs
        val input = inEndpoint ?: throw WiredUsbException("usb_closed", "USB session is closed.")
        while (System.currentTimeMillis() < deadline) {
            if (readPos >= readLen) {
                val remaining = (deadline - System.currentTimeMillis()).coerceAtLeast(1L)
                val n = connection.bulkTransfer(
                    input,
                    readBuffer,
                    readBuffer.size,
                    remaining.coerceAtMost(1000L).toInt()
                )
                if (n <= 0) continue
                readPos = 0
                readLen = n
            }
            val b = readBuffer[readPos++].toInt() and 0xFF
            if (b == 10) {
                return out.toString().trim { it <= ' ' }
            }
            if (b != 13) {
                out.append(b.toChar())
            }
        }
        throw WiredUsbException("wired_timeout", "Timed out while reading USB line.")
    }

    private fun readExactBytes(length: Int, timeoutMs: Long): ByteArray {
        val result = ByteArray(length)
        var offset = 0
        val deadline = System.currentTimeMillis() + timeoutMs
        val input = inEndpoint ?: throw WiredUsbException("usb_closed", "USB session is closed.")
        while (offset < length && System.currentTimeMillis() < deadline) {
            if (readPos < readLen) {
                val n = minOf(length - offset, readLen - readPos)
                System.arraycopy(readBuffer, readPos, result, offset, n)
                readPos += n
                offset += n
                continue
            }
            val remainingTime = (deadline - System.currentTimeMillis()).coerceAtLeast(1L)
            val n = connection.bulkTransfer(
                input,
                readBuffer,
                readBuffer.size,
                remainingTime.coerceAtMost(1000L).toInt()
            )
            if (n <= 0) continue
            readPos = 0
            readLen = n
        }
        if (offset != length) {
            throw WiredUsbException(
                "wired_timeout",
                "Timed out while reading USB binary chunk ($offset / $length bytes)."
            )
        }
        return result
    }

    private fun drainStartupNoise() {
        val deadline = System.currentTimeMillis() + 250
        val input = inEndpoint ?: return
        while (System.currentTimeMillis() < deadline) {
            val n = connection.bulkTransfer(input, readBuffer, readBuffer.size, 20)
            if (n <= 0) continue
        }
        readPos = 0
        readLen = 0
    }

    private fun recoverProtocolOnOpen() {
        try {
            cancelTransfer()
        } catch (_: Exception) {
        }
        try {
            writeLine("wr-cancel")
        } catch (_: Exception) {
        }
        drainUntilQuiet(maxMs = 2500, quietMs = 250)
    }

    private fun drainUntilQuiet(maxMs: Long, quietMs: Long) {
        val input = inEndpoint ?: return
        val startedAt = System.currentTimeMillis()
        val deadline = startedAt + maxMs
        var lastDataAt = startedAt
        var sawData = false

        while (System.currentTimeMillis() < deadline) {
            val n = connection.bulkTransfer(input, readBuffer, readBuffer.size, 50)
            val now = System.currentTimeMillis()
            if (n > 0) {
                sawData = true
                lastDataAt = now
                continue
            }
            if (!sawData && now - startedAt >= quietMs) {
                break
            }
            if (sawData && now - lastDataAt >= quietMs) {
                break
            }
        }

        readPos = 0
        readLen = 0
    }

    companion object {
        fun canUse(device: UsbDevice): Boolean {
            var hasData = false
            var hasBulkIn = false
            var hasBulkOut = false
            for (i in 0 until device.interfaceCount) {
                val iface = device.getInterface(i)
                if (iface.interfaceClass == UsbConstants.USB_CLASS_CDC_DATA) {
                    hasData = true
                    for (e in 0 until iface.endpointCount) {
                        val ep = iface.getEndpoint(e)
                        if (ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK) {
                            if (ep.direction == UsbConstants.USB_DIR_IN) hasBulkIn = true
                            if (ep.direction == UsbConstants.USB_DIR_OUT) hasBulkOut = true
                        }
                    }
                }
            }
            return hasData && hasBulkIn && hasBulkOut
        }
    }
}
