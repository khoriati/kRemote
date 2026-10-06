import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../../../domain/entities/remote_device.dart';
import '../../../domain/errors.dart';
import '../../../domain/ports/pairing_flow.dart';
import '../../net/log.dart';
import '../../net/protobuf.dart';
import '../../net/tls_trust.dart';
import 'android_tv_certificate.dart';

/// Cálculo do segredo de emparelhamento (puro, testável).
///
/// `SHA-256(clientN ‖ clientE ‖ serverN ‖ serverE ‖ nonce)` onde `nonce` são
/// os 4 últimos dígitos hex do PIN. Os 2 primeiros dígitos do PIN devem
/// coincidir com o primeiro byte do hash.
class PairingSecret {
  static Uint8List compute({required RsaPublicNumbers client, required RsaPublicNumbers server, required String pin}) {
    final normalized = pin.trim().toUpperCase();
    if (!RegExp(r'^[0-9A-F]{6}$').hasMatch(normalized)) {
      throw const PairingException('O código deve ter 6 caracteres hexadecimais');
    }
    final nonce = RsaPublicNumbers.minimalBytes(BigInt.parse(normalized.substring(2), radix: 16));
    final paddedNonce = Uint8List(2)..setRange(2 - nonce.length, 2, nonce);
    final data = <int>[
      ...RsaPublicNumbers.minimalBytes(client.modulus),
      ...RsaPublicNumbers.minimalBytes(client.exponent),
      ...RsaPublicNumbers.minimalBytes(server.modulus),
      ...RsaPublicNumbers.minimalBytes(server.exponent),
      ...paddedNonce,
    ];
    final hash = Uint8List.fromList(crypto.sha256.convert(data).bytes);
    final check = int.parse(normalized.substring(0, 2), radix: 16);
    if (hash[0] != check) {
      throw const PairingException('Código incorreto. Confira o código exibido na TV.');
    }
    return hash;
  }
}

/// Codificação das mensagens `PairingMessage` (pairingmessage.proto).
class PairingMessages {
  static const protocolVersion = 2;
  static const statusOk = 200;
  static const encodingHex = 3;
  static const roleInput = 1;

  static Uint8List _wrap(int field, ProtoWriter inner) {
    final w = ProtoWriter()
      ..int32(1, protocolVersion)
      ..int32(2, statusOk)
      ..message(field, inner);
    return ProtoWriter.frameVarint(w.toBytes());
  }

  static Uint8List pairingRequest(String clientName) => _wrap(
    10,
    ProtoWriter()
      ..string(1, 'androidtvremote')
      ..string(2, clientName),
  );

  static Uint8List pairingOption() {
    final enc = ProtoWriter()
      ..int32(1, encodingHex)
      ..int32(2, 6);
    return _wrap(
      20,
      ProtoWriter()
        ..message(1, enc)
        ..int32(3, roleInput),
    );
  }

  static Uint8List pairingConfiguration() {
    final enc = ProtoWriter()
      ..int32(1, encodingHex)
      ..int32(2, 6);
    return _wrap(
      30,
      ProtoWriter()
        ..message(1, enc)
        ..int32(2, roleInput),
    );
  }

  static Uint8List pairingSecret(Uint8List secret) => _wrap(40, ProtoWriter()..bytes(1, secret));
}

/// Fluxo de emparelhamento Android TV Remote v2 (porta 6467, TLS mútuo).
class AndroidTvPairingFlow implements PairingFlow {
  AndroidTvPairingFlow(
    this.device,
    this.trust, {
    ClientIdentity? identity,
    Future<ClientIdentity> Function()? identityProvider,
    this.clientName = 'kRemote',
  }) : _identity = identity, // ignore: prefer_initializing_formals
       _identityProvider = identityProvider; // ignore: prefer_initializing_formals

  final RemoteDevice device;
  final TlsTrust trust;
  final String clientName;

  /// Identidade do cliente. Se ausente, obtida de [_identityProvider] (ou
  /// gerada em isolate) no [start], sem bloquear a UI.
  ClientIdentity? _identity;
  final Future<ClientIdentity> Function()? _identityProvider;

  final _state = StreamController<PairingState>.broadcast();
  final _buffer = <int>[];
  SecureSocket? _socket;
  RsaPublicNumbers? _serverKey;
  Map<String, String>? _credentials;
  var _stage = PairingStage.idle;

  @override
  Stream<PairingState> get state => _state.stream;

  @override
  Map<String, String>? get credentials => _credentials;

  void _emit(PairingStage stage, [String? message]) {
    _stage = stage;
    KLog.d('atv-pairing', '$stage ${message ?? ''}');
    if (!_state.isClosed) _state.add(PairingState(stage, message: message));
  }

  @override
  Future<void> start() async {
    _emit(PairingStage.connecting, 'Preparando identidade…');
    try {
      final identity = _identity ??= await (_identityProvider?.call() ?? ClientIdentity.generateAsync());
      if (_stage == PairingStage.failure) return; // cancelado durante a geração
      _emit(PairingStage.connecting, 'Conectando à TV…');
      await trust.load();
      final ctx = SecurityContext(withTrustedRoots: false)
        ..useCertificateChainBytes(identity.certificatePem.codeUnits)
        ..usePrivateKeyBytes(identity.privateKeyPem.codeUnits);
      // Fechado em _close() via _socket.destroy().
      // ignore: close_sinks
      final socket = await SecureSocket.connect(
        device.host,
        device.pairingPort ?? 6467,
        context: ctx,
        onBadCertificate: trust.accept,
        timeout: const Duration(seconds: 8),
      );
      _socket = socket;
      final der = socket.peerCertificate?.der;
      if (der == null) throw const PairingException('TV não apresentou certificado');
      _serverKey = RsaPublicNumbers.fromCertificateDer(der);
      socket.listen(_onData, onError: (Object e) => _fail('Conexão perdida: $e'), onDone: _onDone);
      socket.add(PairingMessages.pairingRequest(clientName));
    } on PairingException catch (e) {
      _fail(e.message);
    } on HandshakeException {
      _fail(TlsTrust.describeHandshakeFailure(pinMismatch: trust.pinMismatch).message);
    } catch (e) {
      _fail('Falha ao conectar em ${device.host}:${device.pairingPort ?? 6467} ($e)');
    }
  }

  void _onData(Uint8List data) {
    _buffer.addAll(data);
    Uint8List? frame;
    while ((frame = ProtoReader.takeVarintFrame(_buffer)) != null) {
      try {
        _handle(ProtoReader(frame!).readAll());
      } catch (e) {
        _fail('Mensagem inválida: $e');
      }
    }
  }

  void _handle(Map<int, ProtoField> msg) {
    final status = msg[2]?.asInt ?? PairingMessages.statusOk;
    if (status != PairingMessages.statusOk) {
      final reason = switch (status) {
        402 => 'Código incorreto (a TV rejeitou o segredo)',
        401 => 'Configuração de emparelhamento rejeitada',
        _ => 'A TV recusou o emparelhamento (status $status)',
      };
      _fail(reason);
      return;
    }
    if (msg.containsKey(11)) {
      _socket!.add(PairingMessages.pairingOption());
    } else if (msg.containsKey(20)) {
      _socket!.add(PairingMessages.pairingConfiguration());
    } else if (msg.containsKey(31)) {
      _emit(PairingStage.awaitingPin, 'Digite o código exibido na TV');
    } else if (msg.containsKey(41)) {
      _credentials = _identity!.toCredentials();
      // Marca o sucesso antes de fechar o socket: o `onDone` do fechamento
      // chega antes de o pin ser persistido e não pode virar "falha".
      _stage = PairingStage.success;
      _close();
      unawaited(_finish());
    }
  }

  Future<void> _finish() async {
    try {
      await trust.commit();
    } catch (e) {
      KLog.d('atv-pairing', 'falha ao fixar certificado: $e');
    }
    _emit(PairingStage.success, 'Emparelhado com sucesso');
  }

  @override
  Future<void> submit(String value) async {
    if (_stage != PairingStage.awaitingPin || _socket == null || _serverKey == null) return;
    try {
      final secret = PairingSecret.compute(client: _identity!.publicNumbers, server: _serverKey!, pin: value);
      _emit(PairingStage.connecting, 'Validando código…');
      _socket!.add(PairingMessages.pairingSecret(secret));
    } on PairingException catch (e) {
      _emit(PairingStage.awaitingPin, e.message);
    }
  }

  void _onDone() {
    if (_stage != PairingStage.success && _stage != PairingStage.failure) {
      _fail('A TV encerrou a conexão');
    }
  }

  void _fail(String message) {
    if (_stage == PairingStage.failure || _stage == PairingStage.success) return;
    _emit(PairingStage.failure, message);
    _close();
  }

  void _close() {
    _socket?.destroy();
    _socket = null;
  }

  @override
  Future<void> cancel() async {
    _close();
    if (_stage != PairingStage.success) _emit(PairingStage.failure, 'Cancelado');
    await _state.close();
  }
}
