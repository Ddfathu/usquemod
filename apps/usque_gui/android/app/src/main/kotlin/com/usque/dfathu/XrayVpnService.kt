package com.usque.dfathu

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.net.VpnService
import android.os.ParcelFileDescriptor
import hev.htproxy.TProxyService
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import kotlin.concurrent.thread

/**
 * Mode Inject (Fase 2a): menjalankan xray-core sebagai proses anak dan
 * menjembatani TUN Android ke inbound SOCKS Xray lewat hev-socks5-tunnel
 * (JNI, kelas hev.htproxy.TProxyService dari upstream hev).
 *
 * Service ini sengaja berjalan di proses utama (berbeda dengan
 * UsqueVpnService yang di proses :vpn) agar MainActivity bisa membaca
 * statusnya langsung lewat companion object. Mode ini eksklusif terhadap
 * MASQUE: UI menolak start selama snapshot engine bukan disconnected,
 * dan Builder memakai addDisallowedApplication untuk paket sendiri agar
 * trafik keluar Xray tidak berputar balik masuk TUN.
 */
class XrayVpnService : VpnService() {
    companion object {
        const val ACTION_START = "com.usque.dfathu.xray.START"
        const val ACTION_STOP = "com.usque.dfathu.xray.STOP"
        const val EXTRA_CONFIG_JSON = "config_json"
        const val EXTRA_LABEL = "label"

        private const val NOTIFICATION_ID = 4202
        private const val CHANNEL_ID = "xray_inject"
        private const val SOCKS_PORT = 10808
        private const val TUN_ADDRESS = "198.18.0.1"
        private const val TUN_MTU = 8500

        private const val HEV_CONFIG = """
tunnel:
  mtu: 8500
  ipv4: 198.18.0.1

socks5:
  port: 10808
  address: 127.0.0.1
  udp: 'udp'

misc:
  log-level: info
"""

        @Volatile
        var isRunning: Boolean = false
            private set

        @Volatile
        var lastError: String? = null
            private set

        @Volatile
        private var hevLoadTried: Boolean = false

        @Volatile
        private var hevLoadError: String? = null

        /**
         * Memuat libhev-socks5-tunnel secara eksplisit dan menangkap pesan
         * dlopen aslinya. Tanpa ini, kegagalan load pertama tertelan di
         * stopTunnel dan akses berikutnya hanya melaporkan
         * NoClassDefFoundError tanpa penyebab. Mengembalikan null bila
         * library berhasil dimuat.
         */
        fun hevLoadFailure(): String? {
            if (!hevLoadTried) {
                synchronized(this) {
                    if (!hevLoadTried) {
                        hevLoadTried = true
                        try {
                            System.loadLibrary("hev-socks5-tunnel")
                        } catch (t: Throwable) {
                            hevLoadError =
                                "${t.javaClass.simpleName}: ${t.message ?: t.toString()}"
                        }
                    }
                }
            }
            return hevLoadError
        }

        private val logLock = Any()
        private val logLines = mutableListOf<String>()

        /** Menambah satu baris ke buffer log yang dibaca panel Log di UI. */
        fun appendLog(line: String) {
            synchronized(logLock) {
                logLines.add(line)
                while (logLines.size > 300) {
                    logLines.removeAt(0)
                }
            }
        }

        fun logText(): String = synchronized(logLock) { logLines.joinToString("\n") }

        fun clearLog() {
            synchronized(logLock) { logLines.clear() }
        }

        fun status(): Map<String, Any?> =
            mapOf(
                "running" to isRunning,
                "error" to lastError,
                "log" to logText(),
            )
    }

    private var xrayProcess: Process? = null
    private var tunDescriptor: ParcelFileDescriptor? = null
    private var tunFd: Int = -1
    private var hevRunning: Boolean = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val configJson = intent.getStringExtra(EXTRA_CONFIG_JSON)
                val label = intent.getStringExtra(EXTRA_LABEL) ?: "Xray"
                if (configJson.isNullOrBlank()) {
                    lastError = "Config Xray kosong."
                    stopSelf()
                    return START_NOT_STICKY
                }
                try {
                    startForeground(NOTIFICATION_ID, buildNotification(label))
                } catch (t: Throwable) {
                    lastError =
                        "Gagal masuk foreground: ${t.javaClass.simpleName}: ${t.message ?: t.toString()}"
                    stopSelf()
                    return START_NOT_STICKY
                }
                startTunnel(configJson, label)
                return START_STICKY
            }
            ACTION_STOP -> {
                stopTunnel()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                stopSelf()
                return START_NOT_STICKY
            }
        }
    }

    private fun startTunnel(configJson: String, label: String) {
        stopTunnel()
        lastError = null
        clearLog()
        appendLog("[app] Memulai mode Inject: $label")
        thread(name = "xray-vpn-start") {
            try {
                val dir = File(filesDir, "xray").apply { mkdirs() }
                val configFile = File(dir, "config.json")
                configFile.writeText(configJson)
                val hevFile = File(dir, "hev.yml")
                hevFile.writeText(HEV_CONFIG)

                val xrayBin = File(applicationInfo.nativeLibraryDir, "libxray.so")
                if (!xrayBin.exists()) {
                    throw IllegalStateException(
                        "Binary Xray tidak tersedia untuk ABI perangkat ini.",
                    )
                }
                val hevLib = File(applicationInfo.nativeLibraryDir, "libhev-socks5-tunnel.so")
                if (!hevLib.exists()) {
                    throw IllegalStateException(
                        "Library hev tun2socks tidak ada di APK ini; artifact build tidak lengkap.",
                    )
                }
                hevLoadFailure()?.let { failure ->
                    throw IllegalStateException(
                        "Library hev gagal dimuat di perangkat ini: $failure",
                    )
                }
                val processBuilder =
                    ProcessBuilder(
                        xrayBin.absolutePath,
                        "run",
                        "-config",
                        configFile.absolutePath,
                    )
                processBuilder.directory(dir)
                processBuilder.environment()["XRAY_LOCATION_ASSET"] = dir.absolutePath
                processBuilder.redirectErrorStream(true)
                val process = processBuilder.start()
                xrayProcess = process

                thread(name = "xray-output") {
                    try {
                        process.inputStream.bufferedReader().forEachLine { line ->
                            appendLog(line)
                        }
                    } catch (_: Exception) {
                        // Proses berhenti; pembaca output selesai.
                    }
                }

                if (!awaitSocksReady(process)) {
                    val tail = logText().trim()
                    throw IllegalStateException(
                        "Xray gagal start." +
                            if (tail.isEmpty()) "" else " Log: ${tail.takeLast(400)}",
                    )
                }
                appendLog("[app] Xray berjalan; SOCKS 127.0.0.1:$SOCKS_PORT siap.")

                val vpnBuilder =
                    Builder()
                        .setSession(label)
                        .setMtu(TUN_MTU)
                        .addAddress(TUN_ADDRESS, 30)
                        .addRoute("0.0.0.0", 0)
                        .addDnsServer("1.1.1.1")
                try {
                    vpnBuilder.addDisallowedApplication(packageName)
                } catch (_: PackageManager.NameNotFoundException) {
                    // Paket sendiri selalu terpasang; abaikan.
                }
                val descriptor =
                    vpnBuilder.establish()
                        ?: throw IllegalStateException(
                            "VpnService.establish() gagal; izin VPN belum diberikan?",
                        )
                tunDescriptor = descriptor
                appendLog("[app] TUN terbentuk: $TUN_ADDRESS/30, DNS 1.1.1.1, MTU $TUN_MTU.")
                val fd = descriptor.detachFd()
                tunFd = fd
                val hevStarted =
                    try {
                        TProxyService.TProxyStartService(hevFile.absolutePath, fd)
                    } catch (t: Throwable) {
                        throw IllegalStateException(
                            "hev tun2socks gagal dimuat: ${t.javaClass.simpleName}: ${t.message ?: t.toString()}",
                            t,
                        )
                    }
                if (!hevStarted) {
                    throw IllegalStateException("hev tun2socks gagal start.")
                }
                hevRunning = true
                isRunning = true
                appendLog("[app] hev tun2socks aktif — mode Inject tersambung.")
            } catch (error: Throwable) {
                lastError =
                    "${error.javaClass.simpleName}: ${error.message ?: error.toString()}"
                appendLog("[app] GAGAL: $lastError")
                stopTunnel()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
    }

    private fun awaitSocksReady(process: Process): Boolean {
        val deadline = System.currentTimeMillis() + 8000
        while (System.currentTimeMillis() < deadline) {
            if (!process.isAlive) return false
            try {
                Socket().use { socket ->
                    socket.connect(InetSocketAddress("127.0.0.1", SOCKS_PORT), 250)
                }
                return true
            } catch (_: Exception) {
                Thread.sleep(150)
            }
        }
        return false
    }

    private fun stopTunnel() {
        val wasActive = isRunning || hevRunning || xrayProcess != null
        isRunning = false
        if (wasActive) {
            appendLog("[app] Tunnel dihentikan.")
        }
        if (hevRunning) {
            try {
                if (TProxyService.TProxyIsRunning()) {
                    TProxyService.TProxyStopService()
                }
            } catch (_: Throwable) {
                // Library gagal dimuat atau sudah berhenti; abaikan.
            }
            hevRunning = false
        }
        xrayProcess?.destroy()
        xrayProcess = null
        if (tunFd >= 0) {
            try {
                ParcelFileDescriptor.adoptFd(tunFd).close()
            } catch (_: Exception) {
                // Fd sudah tertutup; abaikan.
            }
            tunFd = -1
        }
        try {
            tunDescriptor?.close()
        } catch (_: Exception) {
            // Sudah tertutup; abaikan.
        }
        tunDescriptor = null
    }

    override fun onRevoke() {
        stopTunnel()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        super.onRevoke()
    }

    override fun onDestroy() {
        stopTunnel()
        super.onDestroy()
    }

    private fun buildNotification(label: String): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Inject Xray",
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
        val stopIntent =
            PendingIntent.getService(
                this,
                0,
                Intent(this, XrayVpnService::class.java).setAction(ACTION_STOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        val openIntent =
            PendingIntent.getActivity(
                this,
                0,
                Intent(this, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Inject — Xray aktif")
            .setContentText(label)
            .setSmallIcon(R.drawable.ic_stat_usque)
            .setContentIntent(openIntent)
            .addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(
                        this,
                        android.R.drawable.ic_menu_close_clear_cancel,
                    ),
                    "Putuskan",
                    stopIntent,
                ).build(),
            )
            .setOngoing(true)
            .build()
    }
}
