import '../../../domain/entities/connection_state.dart';
import '../../../domain/entities/remote_key.dart';
import '../../../domain/errors.dart';
import '../base_controller.dart';
import 'bluetooth_hid_channel.dart';
import 'hid_usage.dart';

/// Celular como teclado Bluetooth para PC/Mac (somente Android).
/// `device.host` guarda o endereço Bluetooth do computador pareado.
class BluetoothHidController extends BaseRemoteController {
  BluetoothHidController(super.device, {BluetoothHidChannel channel = const BluetoothHidChannel()}) : _ch = channel;
  final BluetoothHidChannel _ch;

  @override
  Set<RemoteKey> get supportedKeys => {...hidKeyboardUsages.keys, ...hidConsumerUsages.keys};
  @override
  Set<RemoteCapability> get capabilities => const {RemoteCapability.textInput};

  @override
  Future<void> connect() async {
    if (currentState == DeviceConnectionState.connected) return;
    setState(DeviceConnectionState.connecting);
    try {
      if (!await _ch.isSupported()) {
        throw const ConnectionException('Bluetooth HID não é suportado neste aparelho');
      }
      if (!await _ch.requestPermission()) {
        throw const ConnectionException('Permissão de Bluetooth negada');
      }
      await _ch.registerApp();
      final ok = await _ch.connect(device.host);
      if (!ok) {
        throw const ConnectionException(
          'O computador não aceitou a conexão. Pareie o celular pelo computador com o kRemote aberto.',
        );
      }
      setState(DeviceConnectionState.connected);
    } catch (e) {
      setState(DeviceConnectionState.error);
      throw e is RemoteException ? e : ConnectionException(e.toString());
    }
  }

  @override
  Future<void> disconnect() async {
    await _ch.disconnect();
    setState(DeviceConnectionState.disconnected);
  }

  @override
  Future<void> sendKey(RemoteKey key, {KeyPress press = KeyPress.short}) async {
    if (press == KeyPress.longEnd) return;
    await ensureConnected();
    final kb = hidKeyboardUsages[key];
    if (kb != null) return _ch.sendKeyboard(kb.$1, kb.$2);
    final consumer = hidConsumerUsages[key] ?? unsupported(key);
    await _ch.sendConsumer(consumer);
  }

  @override
  Future<void> sendText(String text) async {
    await ensureConnected();
    for (final rune in text.runes) {
      final u = hidUsageForChar(String.fromCharCode(rune));
      if (u == null) continue;
      await _ch.sendKeyboard(u.$1, u.$2);
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
  }

  @override
  void dispose() {
    _ch.disconnect();
    super.dispose();
  }
}
