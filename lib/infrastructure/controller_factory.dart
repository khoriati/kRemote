import '../domain/entities/remote_device.dart';
import '../domain/ports/certificate_pin_store.dart';
import '../domain/ports/credential_store.dart';
import '../domain/ports/pairing_flow.dart';
import '../domain/ports/remote_controller.dart';
import 'net/log.dart';
import 'net/tls_trust.dart';
import 'protocols/android_tv/android_tv_certificate.dart';
import 'protocols/android_tv/android_tv_controller.dart';
import 'protocols/android_tv/android_tv_pairing.dart';
import 'protocols/bluetooth_hid/bluetooth_hid_controller.dart';
import 'protocols/cast/cast_controller.dart';
import 'protocols/lg/lg_controller.dart';
import 'protocols/philips/philips_controller.dart';
import 'protocols/roku/roku_controller.dart';
import 'protocols/samsung/samsung_controller.dart';
import 'protocols/sony/sony_controller.dart';
import 'protocols/vizio/vizio_controller.dart';

/// Monta o adapter concreto para cada protocolo, injetando credenciais e a
/// política de confiança TLS do dispositivo.
class ControllerFactory {
  ControllerFactory({required this.credentials, required this.pins});

  final CredentialStore credentials;
  final CertificatePinStore pins;

  /// Chave (no CredentialStore) da identidade única do app para Android TV.
  static const appIdentityKey = 'app:android-tv-identity';
  Future<ClientIdentity>? _identityFuture;

  /// Identidade do cliente Android TV compartilhada por todos os aparelhos
  /// (como faz o app Google Home). Gerada uma única vez, em isolate, e
  /// guardada em armazenamento seguro. Chamar cedo aquece o cache.
  Future<ClientIdentity> appIdentity() => _identityFuture ??= _loadOrCreateIdentity();

  Future<ClientIdentity> _loadOrCreateIdentity() async {
    final existing = ClientIdentity.fromCredentials(await credentials.read(appIdentityKey));
    if (existing != null) return existing;
    final sw = Stopwatch()..start();
    final fresh = await ClientIdentity.generateAsync();
    KLog.d('identity', 'identidade Android TV gerada em ${sw.elapsedMilliseconds} ms');
    await credentials.write(appIdentityKey, fresh.toCredentials());
    return fresh;
  }

  TlsTrust _trust(RemoteDevice d) => TlsTrust(deviceId: d.id, store: pins);

  /// Mesma Google TV vista como receptor Cast (porta 8009), para volume.
  static RemoteDevice _castTwin(RemoteDevice d) => RemoteDevice(
    id: '${d.id}-cast',
    name: d.name,
    host: d.host,
    port: RemoteProtocol.cast.defaultPort,
    protocol: RemoteProtocol.cast,
  );

  Future<RemoteController> create(RemoteDevice d) async {
    final creds = await credentials.read(d.id);
    return switch (d.protocol) {
      RemoteProtocol.androidTv => AndroidTvController(
        d,
        ClientIdentity.fromCredentials(creds),
        _trust(d),
        volumeFallback: d.volumeViaCast ? CastController(_castTwin(d), _trust(_castTwin(d))) : null,
      ),
      RemoteProtocol.cast => CastController(d, _trust(d)),
      RemoteProtocol.samsungTizen => SamsungController(d, creds?['token'], _trust(d)),
      RemoteProtocol.lgWebOs => LgController(d, creds?['clientKey'], _trust(d)),
      RemoteProtocol.roku => RokuController(d),
      RemoteProtocol.sonyBravia => SonyController(d, creds?['psk']),
      RemoteProtocol.philipsJointSpace => PhilipsController(d),
      RemoteProtocol.vizioSmartCast => VizioController(d, creds?['authToken'], _trust(d)),
      RemoteProtocol.bluetoothHid => BluetoothHidController(d),
    };
  }

  /// Fluxo de emparelhamento; `null` para protocolos que não o exigem.
  PairingFlow? pairing(RemoteDevice d) => switch (d.protocol) {
    RemoteProtocol.androidTv => AndroidTvPairingFlow(d, _trust(d), identityProvider: appIdentity),
    RemoteProtocol.samsungTizen => SamsungPairingFlow(d, _trust(d)),
    RemoteProtocol.lgWebOs => LgPairingFlow(d, _trust(d)),
    RemoteProtocol.sonyBravia => SonyPairingFlow(d),
    RemoteProtocol.vizioSmartCast => VizioPairingFlow(d, _trust(d)),
    _ => null,
  };

  bool hasPairedCredentials(Map<String, String>? creds, RemoteProtocol p) => switch (p) {
    RemoteProtocol.androidTv => ClientIdentity.fromCredentials(creds) != null,
    RemoteProtocol.samsungTizen => creds?['token'] != null,
    RemoteProtocol.lgWebOs => creds?['clientKey'] != null,
    RemoteProtocol.sonyBravia => creds?['psk'] != null,
    RemoteProtocol.vizioSmartCast => creds?['authToken'] != null,
    _ => true,
  };
}
