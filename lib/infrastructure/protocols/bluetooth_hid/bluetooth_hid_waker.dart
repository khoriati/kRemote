import '../../../domain/errors.dart';
import '../../../domain/ports/wake_source.dart';
import '../../net/log.dart';
import 'bluetooth_hid_channel.dart';
import '../../../domain/entities/remote_key.dart';
import 'hid_usage.dart';

/// Acorda uma Google TV pelo Bluetooth: o celular, pareado à TV como teclado
/// HID, conecta e envia a tecla Power (página Consumer, usage 0x30). O
/// rádio Bluetooth da TV continua ligado em repouso (é como o controle
/// físico a liga), ao contrário do Wi-Fi. Somente Android.
class BluetoothHidWaker implements WakeSource {
  BluetoothHidWaker(this.address, {BluetoothHidChannel channel = const BluetoothHidChannel()}) : _ch = channel;

  final String address;
  final BluetoothHidChannel _ch;

  static const connectAttempts = 2;

  @override
  Future<void> wakeUp() async {
    if (!_ch.isPlatformSupported || !await _ch.isSupported()) {
      throw const ConnectionException('Este celular não pode atuar como teclado Bluetooth');
    }
    if (!await _ch.requestPermission()) throw const ConnectionException('Permissão de Bluetooth negada');
    await _ch.registerApp();
    var ok = false;
    for (var i = 1; i <= connectAttempts && !ok; i++) {
      ok = await _ch.connect(address);
      if (!ok) KLog.d('bt-wake', 'TV $address não aceitou a conexão HID (tentativa $i/$connectAttempts)');
    }
    if (!ok) {
      throw const ConnectionException(
        'A TV não aceitou a conexão Bluetooth. Confira se o celular segue pareado nela (Controles remotos e acessórios).',
      );
    }
    KLog.d('bt-wake', 'conectado à TV $address; enviando Power');
    await _ch.sendConsumer(hidConsumerUsages[RemoteKey.power]!);
    // Alguns aparelhos só acordam com a tecla Power do teclado (0x66).
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _ch.sendKeyboard(0, 0x66);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await _ch.disconnect();
  }
}
