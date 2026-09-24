package br.com.khori.kremote

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHidDevice
import android.bluetooth.BluetoothHidDeviceAppSdpSettings
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Expõe o celular como teclado HID Bluetooth (relatórios de teclado e de
 * controle de mídia) para computadores pareados. Requer API 28+.
 */
class BluetoothHidPlugin(private val activity: Activity, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "br.com.khori.kremote/bt_hid")
    private val main = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private val adapter: BluetoothAdapter? =
        (activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private var hidDevice: BluetoothHidDevice? = null
    private var registered = false
    private var connected: BluetoothDevice? = null
    private var pendingConnect: MethodChannel.Result? = null
    private var pendingConnectAddress: String? = null
    private var pendingPermission: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler(this)
    }

    private fun hasConnectPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            ContextCompat.checkSelfPermission(activity, Manifest.permission.BLUETOOTH_CONNECT) ==
            PackageManager.PERMISSION_GRANTED

    override fun onMethodCall(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" -> result.success(
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && adapter != null &&
                    activity.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH)
            )
            "requestPermission" -> requestPermission(result)
            "bondedDevices" -> {
                if (!hasConnectPermission()) { result.error("PERMISSION", "BLUETOOTH_CONNECT negada", null); return }
                val list = adapter?.bondedDevices?.map { mapOf("name" to it.name, "address" to it.address) } ?: emptyList()
                result.success(list)
            }
            "registerApp" -> registerApp(result)
            "unregisterApp" -> { unregisterApp(); result.success(null) }
            "requestDiscoverable" -> {
                val intent = Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE)
                    .putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, 120)
                activity.startActivity(intent)
                result.success(null)
            }
            "connect" -> connect(call.argument<String>("address"), result)
            "disconnect" -> {
                val d = connected
                if (d != null && hasConnectPermission()) hidDevice?.disconnect(d)
                connected = null
                result.success(null)
            }
            "isConnected" -> result.success(connected?.address == call.argument<String>("address"))
            "sendKeyboard" -> {
                val mods = call.argument<Int>("modifiers") ?: 0
                val usage = call.argument<Int>("usage") ?: 0
                sendKeyboard(mods, usage, result)
            }
            "sendConsumer" -> sendConsumer(call.argument<Int>("usage") ?: 0, result)
            else -> result.notImplemented()
        }
    }

    private fun requestPermission(result: MethodChannel.Result) {
        if (hasConnectPermission()) { result.success(true); return }
        if (pendingPermission != null) { result.success(false); return }
        pendingPermission = result
        androidx.core.app.ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE),
            PERMISSION_REQUEST
        )
    }

    /** Encaminhado por MainActivity.onRequestPermissionsResult. */
    fun onPermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != PERMISSION_REQUEST) return
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        val r = pendingPermission; pendingPermission = null
        r?.success(granted)
    }

    private fun registerApp(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) { result.error("UNSUPPORTED", "API < 28", null); return }
        if (!hasConnectPermission()) { result.error("PERMISSION", "BLUETOOTH_CONNECT negada", null); return }
        if (registered && hidDevice != null) { result.success(null); return }
        val ok = adapter?.getProfileProxy(activity, object : BluetoothProfile.ServiceListener {
            override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
                if (profile != BluetoothProfile.HID_DEVICE) return
                hidDevice = proxy as BluetoothHidDevice
                val sdp = BluetoothHidDeviceAppSdpSettings(
                    "kRemote", "Controle remoto kRemote", "khori",
                    BluetoothHidDevice.SUBCLASS1_COMBO, REPORT_DESCRIPTOR
                )
                try {
                    hidDevice!!.registerApp(sdp, null, null, executor, callback)
                } catch (e: SecurityException) {
                    main.post { result.error("PERMISSION", e.message, null) }
                    return
                }
                main.post { result.success(null) }
            }

            override fun onServiceDisconnected(profile: Int) {
                if (profile == BluetoothProfile.HID_DEVICE) { hidDevice = null; registered = false; connected = null }
            }
        }, BluetoothProfile.HID_DEVICE) ?: false
        if (!ok) result.error("UNAVAILABLE", "Perfil HID indisponível", null)
    }

    private fun unregisterApp() {
        if (!hasConnectPermission()) return
        try { hidDevice?.unregisterApp() } catch (_: SecurityException) {}
        registered = false
        connected = null
    }

    private val callback = object : BluetoothHidDevice.Callback() {
        override fun onAppStatusChanged(pluggedDevice: BluetoothDevice?, isRegistered: Boolean) {
            registered = isRegistered
        }

        override fun onConnectionStateChanged(device: BluetoothDevice, state: Int) {
            when (state) {
                BluetoothProfile.STATE_CONNECTED -> {
                    connected = device
                    if (device.address == pendingConnectAddress) {
                        val r = pendingConnect; pendingConnect = null; pendingConnectAddress = null
                        main.post { r?.success(true) }
                    }
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    if (connected?.address == device.address) connected = null
                    if (device.address == pendingConnectAddress) {
                        val r = pendingConnect; pendingConnect = null; pendingConnectAddress = null
                        main.post { r?.success(false) }
                    }
                }
            }
        }
    }

    private fun connect(address: String?, result: MethodChannel.Result) {
        val hid = hidDevice
        if (address == null || hid == null) { result.success(false); return }
        if (!hasConnectPermission()) { result.error("PERMISSION", "BLUETOOTH_CONNECT negada", null); return }
        if (connected?.address == address) { result.success(true); return }
        val device = adapter?.getRemoteDevice(address) ?: run { result.success(false); return }
        pendingConnect = result
        pendingConnectAddress = address
        val started = try { hid.connect(device) } catch (_: SecurityException) { false }
        if (!started) {
            pendingConnect = null; pendingConnectAddress = null
            result.success(false)
            return
        }
        main.postDelayed({
            if (pendingConnectAddress == address) {
                val r = pendingConnect; pendingConnect = null; pendingConnectAddress = null
                r?.success(false)
            }
        }, 10_000)
    }

    private fun sendKeyboard(modifiers: Int, usage: Int, result: MethodChannel.Result) {
        val hid = hidDevice; val dev = connected
        if (hid == null || dev == null) { result.error("DISCONNECTED", "Sem computador conectado", null); return }
        if (!hasConnectPermission()) { result.error("PERMISSION", "BLUETOOTH_CONNECT negada", null); return }
        val press = byteArrayOf(modifiers.toByte(), 0, usage.toByte(), 0, 0, 0, 0, 0)
        val release = ByteArray(8)
        executor.execute {
            try {
                hid.sendReport(dev, REPORT_ID_KEYBOARD, press)
                Thread.sleep(20)
                hid.sendReport(dev, REPORT_ID_KEYBOARD, release)
                main.post { result.success(null) }
            } catch (e: Exception) {
                main.post { result.error("SEND", e.message, null) }
            }
        }
    }

    private fun sendConsumer(usage: Int, result: MethodChannel.Result) {
        val hid = hidDevice; val dev = connected
        if (hid == null || dev == null) { result.error("DISCONNECTED", "Sem computador conectado", null); return }
        if (!hasConnectPermission()) { result.error("PERMISSION", "BLUETOOTH_CONNECT negada", null); return }
        val press = byteArrayOf((usage and 0xFF).toByte(), ((usage shr 8) and 0xFF).toByte())
        val release = ByteArray(2)
        executor.execute {
            try {
                hid.sendReport(dev, REPORT_ID_CONSUMER, press)
                Thread.sleep(20)
                hid.sendReport(dev, REPORT_ID_CONSUMER, release)
                main.post { result.success(null) }
            } catch (e: Exception) {
                main.post { result.error("SEND", e.message, null) }
            }
        }
    }

    fun dispose() {
        unregisterApp()
        adapter?.closeProfileProxy(BluetoothProfile.HID_DEVICE, hidDevice)
        hidDevice = null
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }

    companion object {
        const val PERMISSION_REQUEST = 0x4B52
        const val REPORT_ID_KEYBOARD = 1
        const val REPORT_ID_CONSUMER = 2

        /** Descritor HID: teclado boot-protocol (report 1) + Consumer Control 16 bits (report 2). */
        val REPORT_DESCRIPTOR: ByteArray = byteArrayOf(
            // Keyboard
            0x05.toByte(), 0x01, 0x09, 0x06, 0xA1.toByte(), 0x01, 0x85.toByte(), REPORT_ID_KEYBOARD.toByte(),
            0x05, 0x07, 0x19, 0xE0.toByte(), 0x29, 0xE7.toByte(), 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95.toByte(), 0x08, 0x81.toByte(), 0x02,
            0x95.toByte(), 0x01, 0x75, 0x08, 0x81.toByte(), 0x01,
            0x95.toByte(), 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81.toByte(), 0x00,
            0xC0.toByte(),
            // Consumer control
            0x05, 0x0C, 0x09, 0x01, 0xA1.toByte(), 0x01, 0x85.toByte(), REPORT_ID_CONSUMER.toByte(),
            0x15, 0x00, 0x26, 0xFF.toByte(), 0x03, 0x19, 0x00, 0x2A, 0xFF.toByte(), 0x03, 0x75, 0x10, 0x95.toByte(), 0x01, 0x81.toByte(), 0x00,
            0xC0.toByte()
        )
    }
}
