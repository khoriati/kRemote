import '../entities/app_shortcut.dart';
import '../entities/connection_state.dart';
import '../entities/remote_device.dart';
import '../entities/remote_key.dart';

/// Porta de saída: controla um dispositivo através de um protocolo concreto.
abstract class RemoteController {
  RemoteDevice get device;

  /// Estado atual da conexão (emite o valor atual ao assinar).
  Stream<DeviceConnectionState> get connectionState;
  DeviceConnectionState get currentState;

  Set<RemoteKey> get supportedKeys;
  Set<RemoteCapability> get capabilities;

  Future<void> connect();
  Future<void> disconnect();

  Future<void> sendKey(RemoteKey key, {KeyPress press = KeyPress.short});

  /// Digita texto no campo com foco (quando [RemoteCapability.textInput]).
  Future<void> sendText(String text) async => throw UnsupportedError('sendText');

  /// Envia um único caractere como pressionamento de tecla (teclado do
  /// controle). Por padrão delega a [sendText].
  Future<void> sendChar(String ch) => sendText(ch);

  /// Abre um app (quando [RemoteCapability.appLaunch]).
  Future<void> launchApp(AppShortcut app) async => throw UnsupportedError('launchApp');

  bool supportsApp(AppShortcut app) =>
      capabilities.contains(RemoteCapability.appLaunch) && app.ids.containsKey(device.protocol.name);

  /// Consulta ao aparelho quais dos [apps] estão realmente instalados.
  ///
  /// Devolve o subconjunto confirmado, ou `null` quando o protocolo não
  /// permite verificar (a UI então mostra todos os atalhos suportados).
  Future<Set<AppShortcut>?> installedApps(List<AppShortcut> apps) async => null;
}
