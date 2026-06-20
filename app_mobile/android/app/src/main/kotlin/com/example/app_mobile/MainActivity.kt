package com.example.app_mobile

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

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
                    val value = when (call.method) {
                        "ping" -> withSession { it.ping() }
                        "pauseRecording" -> withSession { it.pauseRecording() }
                        "resumeRecording" -> withSession { it.resumeRecording() }
                        "listFiles" -> withSession { it.listFiles() }
                        "fetchFile" -> fetchFile(call)
                        "diagnoseUsb" -> diagnoseUsb()
                        else -> throw IllegalArgumentException("Unknown method ${call.method}")
                    }
                    mainHandler.post { result.success(value) }
                } catch (e: WiredUsbException) {
                    mainHandler.post { result.error(e.code, e.message, null) }
                } catch (e: Exception) {
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

    private fun <T> withSession(block: (CdcSession) -> T): T {
        val manager = getSystemService(Context.USB_SERVICE) as UsbManager
        val device = manager.deviceList.values.firstOrNull { CdcSession.canUse(it) }
            ?: throw WiredUsbException(
                "no_usb_device",
                "Mozzy USB device was not found.\n${usbDiagnostics(manager)}"
            )

        if (!manager.hasPermission(device)) {
            if (!requestUsbPermission(manager, device)) {
                throw WiredUsbException("usb_permission", "USB permission was not granted.")
            }
        }

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
        val action = "${packageName}.USB_PERMISSION"
        val latch = CountDownLatch(1)
        var granted = false
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action != action) return
                val returned = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                }
                if (returned?.deviceId == device.deviceId) {
                    granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    latch.countDown()
                }
            }
        }

        val filter = IntentFilter(action)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(receiver, filter)
        }

        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
        val intent = PendingIntent.getBroadcast(this, 0, Intent(action), flags)
        return try {
            manager.requestPermission(device, intent)
            latch.await(30, TimeUnit.SECONDS) && granted
        } finally {
            unregisterReceiver(receiver)
        }
    }
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
    private val readBuffer = ByteArray(4096)
    private var readPos = 0
    private var readLen = 0

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
        val lineCoding = byteArrayOf(
            0x00, 0xC2.toByte(), 0x01, 0x00, // 115200 baud
            0x00, // 1 stop bit
            0x00, // no parity
            0x08, // 8 data bits
        )
        connection.controlTransfer(0x21, 0x20, 0, controlIndex, lineCoding, lineCoding.size, 1000)
        connection.controlTransfer(0x21, 0x22, 0x03, controlIndex, null, 0, 1000)

        inEndpoint = inEp
        outEndpoint = outEp
        drainStartupNoise()
    }

    fun close() {
        dataInterface?.let { connection.releaseInterface(it) }
        controlInterface?.let { connection.releaseInterface(it) }
        connection.close()
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

    fun fetchFile(name: String, destination: File): Long {
        requireSafeName(name)
        destination.parentFile?.mkdirs()
        writeLine("wr-fetch $name")
        val begin = readUntilPrefix("WR-FETCH-BEGIN ", 15000)
        val parts = begin.split(' ')
        val expected = parts.lastOrNull()?.toLongOrNull() ?: -1L
        var written = 0L
        FileOutputStream(destination).use { out ->
            while (true) {
                val line = readLine(30000)
                when {
                    line.startsWith("WR-DATA ") -> {
                        val bytes = Base64.decode(
                            line.removePrefix("WR-DATA "),
                            Base64.DEFAULT
                        )
                        out.write(bytes)
                        written += bytes.size.toLong()
                    }
                    line.startsWith("WR-END") -> {
                        out.fd.sync()
                        if (expected >= 0 && written != expected) {
                            throw WiredUsbException(
                                "wired_size_mismatch",
                                "Expected $expected bytes but received $written bytes."
                            )
                        }
                        return written
                    }
                    line.startsWith("WR-ERR") -> throw WiredUsbException("wired_protocol", line)
                }
            }
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
            if (line.startsWith("WR-ERR")) {
                throw WiredUsbException("wired_protocol", line)
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
