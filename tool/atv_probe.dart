// Sonda de linha de comando para validar o protocolo Android TV Remote v2
// contra um aparelho real, sem precisar do app.
//
//   dart run tool/atv_probe.dart <host> probe          # TLS + PairingRequest/Ack e encerra
//   dart run tool/atv_probe.dart <host> pair           # emparelha (pede o PIN) e salva identidade
//   dart run tool/atv_probe.dart <host> key <tecla>    # envia tecla (ex.: mute, home, volumeUp)
//   dart run tool/atv_probe.dart <host> app <id>       # abre app (youtube, netflix…)
//
// A identidade fica em ~/.kremote-probe/<host>.json (apenas para testes locais).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kremote/domain/entities/app_shortcut.dart';
import 'package:kremote/domain/entities/connection_state.dart';
import 'package:kremote/domain/entities/remote_device.dart';
import 'package:kremote/domain/entities/remote_key.dart';
import 'package:kremote/domain/ports/certificate_pin_store.dart';
import 'package:kremote/domain/ports/pairing_flow.dart';
import 'package:kremote/infrastructure/net/log.dart';
import 'package:kremote/infrastructure/net/protobuf.dart';
import 'package:kremote/infrastructure/net/tls_trust.dart';
import 'package:kremote/infrastructure/protocols/android_tv/android_tv_certificate.dart';
import 'package:kremote/infrastructure/protocols/android_tv/android_tv_controller.dart';
import 'package:kremote/infrastructure/protocols/android_tv/android_tv_pairing.dart';

class FilePinStore implements CertificatePinStore {
  FilePinStore(this.file);
  final File file;
  Map<String, dynamic> _read() => file.existsSync() ? jsonDecode(file.readAsStringSync()) as Map<String, dynamic> : {};
  void _write(Map<String, dynamic> m) => file.writeAsStringSync(jsonEncode(m));
  @override
  Future<String?> read(String deviceId) async => _read()['pin'] as String?;
  @override
  Future<void> write(String deviceId, String sha256Hex) async => _write(_read()..['pin'] = sha256Hex);
  @override
  Future<void> delete(String deviceId) async => _write(_read()..remove('pin'));
}

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('uso: atv_probe <host> probe|pair|key <tecla>|app <id>');
    exit(64);
  }
  KLog.sink = (s, m) => stderr.writeln('[$s] $m');
  final host = args[0];
  final cmd = args[1];
  final dir = Directory('${Platform.environment['HOME']}/.kremote-probe')..createSync(recursive: true);
  final file = File('${dir.path}/$host.json');
  final device = RemoteDevice(
    id: 'probe-$host',
    name: host,
    host: host,
    port: 6466,
    protocol: RemoteProtocol.androidTv,
    pairingPort: 6467,
  );
  final pins = FilePinStore(file);

  switch (cmd) {
    case 'probe':
      await probe(host);
    case 'pair':
      await pair(device, pins, file);
    case 'key':
      await withController(device, pins, file, (c) => c.sendKey(RemoteKey.values.byName(args[2])));
    case 'app':
      await withController(device, pins, file, (c) => c.launchApp(AppShortcut.all.firstWhere((a) => a.id == args[2])));
    default:
      stderr.writeln('comando desconhecido');
      exit(64);
  }
  exit(0);
}

/// Conecta em 6467 com identidade descartável e valida TLS + PairingRequestAck.
Future<void> probe(String host) async {
  final sw = Stopwatch()..start();
  final id = ClientIdentity.generate();
  stdout.writeln('identidade gerada em ${sw.elapsedMilliseconds} ms');
  final ctx = SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(id.certificatePem.codeUnits)
    ..usePrivateKeyBytes(id.privateKeyPem.codeUnits);
  final s = await SecureSocket.connect(
    host,
    6467,
    context: ctx,
    onBadCertificate: (_) => true,
    timeout: const Duration(seconds: 8),
  );
  final peer = s.peerCertificate!;
  final numbers = RsaPublicNumbers.fromCertificateDer(peer.der);
  stdout.writeln('TLS ok: subject=${peer.subject} modulus=${numbers.modulus.bitLength} bits e=${numbers.exponent}');
  final buf = <int>[];
  final done = Completer<void>();
  s.listen(
    (d) {
      buf.addAll(d);
      final frame = ProtoReader.takeVarintFrame(buf);
      if (frame == null) return;
      final m = ProtoReader(frame).readAll();
      stdout.writeln('resposta: campos=${m.keys.toList()} status=${m[2]?.asInt}');
      if (m.containsKey(11)) {
        stdout.writeln('PairingRequestAck recebido: server_name=${m[11]!.asMessage.readAll()[1]?.asString}');
      }
      if (!done.isCompleted) done.complete();
    },
    onError: (Object e) => done.completeError(e),
    onDone: () {
      if (!done.isCompleted) done.completeError('conexão encerrada sem resposta');
    },
  );
  s.add(PairingMessages.pairingRequest('kRemote-probe'));
  await done.future.timeout(const Duration(seconds: 8));
  s.destroy();
}

Future<void> pair(RemoteDevice device, CertificatePinStore pins, File file) async {
  final flow = AndroidTvPairingFlow(device, TlsTrust(deviceId: device.id, store: pins));
  final done = Completer<void>();
  flow.state.listen((st) {
    stdout.writeln('${st.stage.name}: ${st.message ?? ''}');
    if (st.stage == PairingStage.awaitingPin) {
      stdout.write('PIN exibido na TV: ');
      final pin = stdin.readLineSync() ?? '';
      flow.submit(pin);
    } else if (st.stage == PairingStage.success) {
      final existing = file.existsSync()
          ? jsonDecode(file.readAsStringSync()) as Map<String, dynamic>
          : <String, dynamic>{};
      existing['credentials'] = flow.credentials;
      file.writeAsStringSync(jsonEncode(existing));
      stdout.writeln('identidade salva em ${file.path}');
      done.complete();
    } else if (st.stage == PairingStage.failure) {
      done.completeError(st.message ?? 'falha');
    }
  });
  await flow.start();
  await done.future;
}

Future<void> withController(
  RemoteDevice device,
  CertificatePinStore pins,
  File file,
  Future<void> Function(AndroidTvController) act,
) async {
  final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final creds = (data['credentials'] as Map<String, dynamic>).map((k, v) => MapEntry(k, v as String));
  final c = AndroidTvController(
    device,
    ClientIdentity.fromCredentials(creds)!,
    TlsTrust(deviceId: device.id, store: pins),
  );
  c.connectionState.listen((s) => stdout.writeln('estado: ${s.name}'));
  await c.connect();
  if (c.currentState != DeviceConnectionState.connected) throw StateError('não conectou');
  await act(c);
  await Future<void>.delayed(const Duration(milliseconds: 500));
  await c.disconnect();
}
