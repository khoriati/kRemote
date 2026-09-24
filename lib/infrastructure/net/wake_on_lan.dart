import 'dart:io';
import 'dart:typed_data';

/// Envia um magic packet Wake-on-LAN para [mac] (formatos `AA:BB:..`, `AA-BB-..`).
class WakeOnLan {
  const WakeOnLan();

  static Uint8List magicPacket(String mac) {
    final clean = mac.replaceAll(RegExp('[^0-9A-Fa-f]'), '');
    if (clean.length != 12) throw ArgumentError('MAC inválido: $mac');
    final macBytes = List<int>.generate(6, (i) => int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16));
    return Uint8List.fromList([...List.filled(6, 0xff), for (var i = 0; i < 16; i++) ...macBytes]);
  }

  Future<void> wake(String mac, {String? host}) async {
    final packet = magicPacket(mac);
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    try {
      socket.broadcastEnabled = true;
      for (final port in const [9, 7]) {
        socket.send(packet, InternetAddress('255.255.255.255'), port);
        if (host != null) socket.send(packet, InternetAddress(host), port);
      }
    } finally {
      socket.close();
    }
  }
}
