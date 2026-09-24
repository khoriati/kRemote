import 'dart:io';

import 'package:flutter/services.dart';

/// Ponte para a implementação nativa Android de `BluetoothHidDevice`.
class BluetoothHidChannel {
  const BluetoothHidChannel([this._channel = const MethodChannel('br.com.khori.kremote/bt_hid')]);
  final MethodChannel _channel;

  bool get isPlatformSupported => Platform.isAndroid;

  Future<bool> isSupported() async {
    if (!isPlatformSupported) return false;
    return await _channel.invokeMethod<bool>('isSupported') ?? false;
  }

  /// Solicita BLUETOOTH_CONNECT/ADVERTISE (Android 12+). Verdadeiro se concedida.
  Future<bool> requestPermission() async {
    if (!isPlatformSupported) return false;
    return await _channel.invokeMethod<bool>('requestPermission') ?? false;
  }

  /// Dispositivos já pareados no sistema: `[{name, address}]`.
  Future<List<({String name, String address})>> bondedDevices() async {
    final raw = await _channel.invokeListMethod<Map<Object?, Object?>>('bondedDevices') ?? [];
    return raw.map((m) => (name: (m['name'] as String?) ?? 'Dispositivo', address: m['address'] as String)).toList();
  }

  /// Registra o celular como teclado HID e o torna visível para pareamento.
  Future<void> registerApp() => _channel.invokeMethod<void>('registerApp');

  Future<void> unregisterApp() => _channel.invokeMethod<void>('unregisterApp');

  Future<void> requestDiscoverable() => _channel.invokeMethod<void>('requestDiscoverable');

  Future<bool> connect(String address) async =>
      await _channel.invokeMethod<bool>('connect', {'address': address}) ?? false;

  Future<void> disconnect() => _channel.invokeMethod<void>('disconnect');

  Future<bool> isConnected(String address) async =>
      await _channel.invokeMethod<bool>('isConnected', {'address': address}) ?? false;

  Future<void> sendKeyboard(int modifiers, int usage) =>
      _channel.invokeMethod<void>('sendKeyboard', {'modifiers': modifiers, 'usage': usage});

  Future<void> sendConsumer(int usage) => _channel.invokeMethod<void>('sendConsumer', {'usage': usage});
}
