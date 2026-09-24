import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../domain/ports/certificate_pin_store.dart';
import '../../domain/ports/credential_store.dart';

/// Credenciais e pins TLS no Keychain (iOS) / Keystore (Android).
class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(resetOnError: true, storageNamespace: 'kremote'),
            iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
          );

  final FlutterSecureStorage _storage;

  static String _credKey(String id) => 'cred:$id';
  static String _pinKey(String id) => 'pin:$id';

  @override
  Future<Map<String, String>?> read(String deviceId) async {
    final raw = await _storage.read(key: _credKey(deviceId));
    if (raw == null) return null;
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return map.map((k, v) => MapEntry(k, v as String));
  }

  @override
  Future<void> write(String deviceId, Map<String, String> credentials) =>
      _storage.write(key: _credKey(deviceId), value: jsonEncode(credentials));

  @override
  Future<void> delete(String deviceId) async {
    await _storage.delete(key: _credKey(deviceId));
    await _storage.delete(key: _pinKey(deviceId));
  }

  Future<String?> readPin(String deviceId) => _storage.read(key: _pinKey(deviceId));
  Future<void> writePin(String deviceId, String sha256Hex) => _storage.write(key: _pinKey(deviceId), value: sha256Hex);
  Future<void> deletePin(String deviceId) => _storage.delete(key: _pinKey(deviceId));

  /// Visão como [CertificatePinStore].
  CertificatePinStore get pins => _PinView(this);
}

class _PinView implements CertificatePinStore {
  _PinView(this._s);
  final SecureCredentialStore _s;
  @override
  Future<String?> read(String deviceId) => _s.readPin(deviceId);
  @override
  Future<void> write(String deviceId, String sha256Hex) => _s.writePin(deviceId, sha256Hex);
  @override
  Future<void> delete(String deviceId) => _s.deletePin(deviceId);
}
