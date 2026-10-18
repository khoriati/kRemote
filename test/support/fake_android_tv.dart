import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:kremote/infrastructure/net/protobuf.dart';
import 'package:kremote/infrastructure/protocols/android_tv/android_tv_certificate.dart';

/// Servidor de emparelhamento Android TV falso, fiel ao fluxo real:
/// TLS mútuo, PairingRequest → Ack → Option → Configuration → Ack → Secret.
class FakePairingServer {
  FakePairingServer(this.identity, {required this.trustedClientPem});

  final ClientIdentity identity;
  final String trustedClientPem;
  late SecureServerSocket _server;
  final _pinReady = Completer<String>();
  final received = <int>[];
  int? lastSecretStatus;

  int get port => _server.port;

  /// PIN que a "TV" exibiria, disponível após a configuração.
  Future<String> get pin => _pinReady.future;

  Future<void> start() async {
    final ctx = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(identity.certificatePem.codeUnits)
      ..usePrivateKeyBytes(identity.privateKeyPem.codeUnits)
      ..setTrustedCertificatesBytes(trustedClientPem.codeUnits)
      ..setClientAuthoritiesBytes(trustedClientPem.codeUnits);
    _server = await SecureServerSocket.bind('127.0.0.1', 0, ctx, requestClientCertificate: true);
    _server.listen(_serve, onError: (Object _) {});
  }

  Uint8List _wrap(int field, ProtoWriter inner, {int status = 200}) => ProtoWriter.frameVarint(
    (ProtoWriter()
          ..int32(1, 2)
          ..int32(2, status)
          ..message(field, inner))
        .toBytes(),
  );

  void _serve(SecureSocket socket) {
    final clientDer = socket.peerCertificate!.der;
    final client = RsaPublicNumbers.fromCertificateDer(clientDer);
    final server = identity.publicNumbers;
    final buf = <int>[];
    Uint8List? expected;
    socket.listen((data) {
      buf.addAll(data);
      Uint8List? frame;
      while ((frame = ProtoReader.takeVarintFrame(buf)) != null) {
        final m = ProtoReader(frame!).readAll();
        final field = m.keys.firstWhere((k) => k >= 10);
        received.add(field);
        switch (field) {
          case 10:
            socket.add(_wrap(11, ProtoWriter()..string(1, 'Fake TV')));
          case 20:
            final enc = ProtoWriter()
              ..int32(1, 3)
              ..int32(2, 6);
            socket.add(
              _wrap(
                20,
                ProtoWriter()
                  ..message(2, enc)
                  ..int32(3, 2),
              ),
            );
          case 30:
            socket.add(_wrap(31, ProtoWriter()));
            // Gera nonce e PIN exatamente como a TV.
            final nonce = Uint8List.fromList([0x4A, 0xB3]);
            final hash = crypto.sha256.convert([
              ...RsaPublicNumbers.minimalBytes(client.modulus),
              ...RsaPublicNumbers.minimalBytes(client.exponent),
              ...RsaPublicNumbers.minimalBytes(server.modulus),
              ...RsaPublicNumbers.minimalBytes(server.exponent),
              ...nonce,
            ]).bytes;
            expected = Uint8List.fromList(hash);
            String hex(int b) => b.toRadixString(16).padLeft(2, '0').toUpperCase();
            if (!_pinReady.isCompleted) _pinReady.complete('${hex(hash[0])}${hex(nonce[0])}${hex(nonce[1])}');
          case 40:
            final secret = m[40]!.asMessage.readAll()[1]!.asBytes;
            final ok = expected != null && _eq(secret, expected!);
            lastSecretStatus = ok ? 200 : 402;
            socket.add(_wrap(41, ProtoWriter()..bytes(1, expected ?? Uint8List(0)), status: lastSecretStatus!));
            // Como a TV real: encerra a conexão logo após responder ao segredo.
            if (ok) {
              // O cliente pode derrubar a conexão antes do flush: ignora.
              unawaited(socket.close().catchError((_) => socket));
            } else {
              socket.destroy();
            }
        }
      }
    }, onError: (_) {});
  }

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> close() => _server.close();
}

/// Servidor de controle Android TV falso (porta 6466 real).
class FakeRemoteServer {
  FakeRemoteServer(this.identity, {required this.trustedClientPem});
  final ClientIdentity identity;
  final String trustedClientPem;
  late SecureServerSocket _server;
  final keyInjects = <(int, int)>[];
  final appLinks = <String>[];

  /// Links que a "TV" recusa com `remote_error`.
  final rejectedLinks = <String>{};
  final imeEdits = <(int, int, String)>[];
  SecureSocket? _client;

  /// Voz: sessão aberta ao receber KEYCODE_SEARCH (84), payloads e fins recebidos.
  int voiceSessionId = 5;
  bool voiceEnabled = true;
  final voiceBegins = <int>[];
  final voicePayloads = <(int, Uint8List)>[];
  final voiceEnds = <int>[];

  /// Quantas conexões iniciais a "TV" fecha logo após o handshake, sem
  /// mensagem (como faz ao acordar ou com a sessão anterior ainda viva).
  int dropFirstConnections = 0;
  int connections = 0;

  /// Simula a TV anunciando um campo de texto em foco.
  void focusTextField({int imeCounter = 7, int fieldCounter = 3, String value = ''}) {
    final appInfo = ProtoWriter()
      ..int32(1, imeCounter)
      ..string(16, 'com.example.tv');
    final status = ProtoWriter()
      ..int32(1, fieldCounter)
      ..string(2, value);
    _client?.add(
      _msg(
        20,
        ProtoWriter()
          ..message(1, appInfo)
          ..message(2, status),
      ),
    );
  }

  final configured = Completer<void>();
  final activated = Completer<void>();
  final ponged = Completer<int>();

  int get port => _server.port;

  Future<void> start() async {
    final ctx = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(identity.certificatePem.codeUnits)
      ..usePrivateKeyBytes(identity.privateKeyPem.codeUnits)
      ..setTrustedCertificatesBytes(trustedClientPem.codeUnits)
      ..setClientAuthoritiesBytes(trustedClientPem.codeUnits);
    _server = await SecureServerSocket.bind('127.0.0.1', 0, ctx, requestClientCertificate: true);
    // Handshakes abortados pelo cliente (ex.: dispose durante um reconnect)
    // chegam como erro assíncrono fora do stream; não podem derrubar o teste.
    runZonedGuarded(() => _server.listen(_serve, onError: (Object _) {}), (_, _) {});
  }

  Uint8List _msg(int field, ProtoWriter inner) =>
      ProtoWriter.frameVarint((ProtoWriter()..message(field, inner)).toBytes());

  void _serve(SecureSocket socket) {
    if (connections++ < dropFirstConnections) {
      socket.destroy();
      return;
    }
    _client = socket;
    final buf = <int>[];
    final info = ProtoWriter()
      ..string(1, 'FakeTV')
      ..string(2, 'Test');
    socket.add(
      _msg(
        1,
        ProtoWriter()
          ..int32(1, 622)
          ..message(2, info),
      ),
    );
    socket.listen((data) {
      buf.addAll(data);
      Uint8List? frame;
      while ((frame = ProtoReader.takeVarintFrame(buf)) != null) {
        final m = ProtoReader(frame!).readAll();
        if (m.containsKey(1)) {
          if (!configured.isCompleted) configured.complete();
          socket.add(_msg(2, ProtoWriter()..int32(1, 622)));
        } else if (m.containsKey(2)) {
          if (!activated.isCompleted) activated.complete();
          socket.add(_msg(8, ProtoWriter()..int32(1, 42)));
        } else if (m.containsKey(9)) {
          if (!ponged.isCompleted) ponged.complete(m[9]!.asMessage.readAll()[1]!.asInt);
        } else if (m.containsKey(10)) {
          final k = m[10]!.asMessage.readAll();
          keyInjects.add((k[1]!.asInt, k[2]!.asInt));
          if (k[1]!.asInt == 84 && voiceEnabled) {
            socket.add(
              _msg(
                30,
                ProtoWriter()
                  ..int32(1, voiceSessionId)
                  ..string(2, 'com.google.android.katniss'),
              ),
            );
          }
        } else if (m.containsKey(30)) {
          voiceBegins.add(m[30]!.asMessage.readAll()[1]!.asInt);
        } else if (m.containsKey(31)) {
          final v = m[31]!.asMessage.readAll();
          voicePayloads.add((v[1]!.asInt, v[2]!.asBytes));
        } else if (m.containsKey(32)) {
          voiceEnds.add(m[32]!.asMessage.readAll()[1]!.asInt);
        } else if (m.containsKey(90)) {
          final link = m[90]!.asMessage.readAll()[1]!.asString;
          appLinks.add(link);
          if (rejectedLinks.contains(link)) {
            // Como a TV real: remote_error 7 e fecha a conexão.
            socket.add(_msg(3, ProtoWriter()..int32(1, 7)));
            unawaited(socket.close().catchError((_) => socket));
          }
        } else if (m.containsKey(21)) {
          final batch = m[21]!.asMessage.readAll();
          final status = batch[3]!.asMessage.readAll()[2]!.asMessage.readAll();
          imeEdits.add((batch[1]!.asInt, batch[2]!.asInt, status[2]!.asString));
        }
      }
    }, onError: (_) {});
  }

  Future<void> close() => _server.close();
}
