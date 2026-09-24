import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../domain/entities/app_shortcut.dart';
import '../../../domain/entities/connection_state.dart';
import '../../../domain/entities/remote_key.dart';
import '../../../domain/errors.dart';
import '../../net/protobuf.dart';
import '../../net/tls_trust.dart';
import '../base_controller.dart';

/// Codec do envelope `CastMessage` (cast_channel.proto), framing de 4 bytes BE.
class CastMessageCodec {
  static const nsConnection = 'urn:x-cast:com.google.cast.tp.connection';
  static const nsHeartbeat = 'urn:x-cast:com.google.cast.tp.heartbeat';
  static const nsReceiver = 'urn:x-cast:com.google.cast.receiver';
  static const nsMedia = 'urn:x-cast:com.google.cast.media';

  static Uint8List encode({
    required String source,
    required String destination,
    required String namespace,
    required Map<String, dynamic> payload,
  }) {
    final w = ProtoWriter()
      ..int32(1, 0)
      ..string(2, source)
      ..string(3, destination)
      ..string(4, namespace)
      ..int32(5, 0)
      ..string(6, jsonEncode(payload));
    final body = w.toBytes();
    final len = ByteData(4)..setUint32(0, body.length, Endian.big);
    return Uint8List.fromList([...len.buffer.asUint8List(), ...body]);
  }

  /// Decodifica um frame já sem o prefixo de tamanho.
  static ({String source, String destination, String namespace, Map<String, dynamic>? payload}) decode(
    Uint8List frame,
  ) {
    final f = ProtoReader(frame).readAll();
    Map<String, dynamic>? payload;
    final raw = f[6];
    if (raw != null) {
      final decoded = jsonDecode(raw.asString);
      if (decoded is Map<String, dynamic>) payload = decoded;
    }
    return (
      source: f[2]?.asString ?? '',
      destination: f[3]?.asString ?? '',
      namespace: f[4]?.asString ?? '',
      payload: payload,
    );
  }

  /// Extrai um frame `uint32 BE len + payload` de [buffer]; `null` se incompleto.
  static Uint8List? takeFrame(List<int> buffer) {
    if (buffer.length < 4) return null;
    final len = ByteData.sublistView(Uint8List.fromList(buffer.sublist(0, 4))).getUint32(0, Endian.big);
    if (buffer.length < 4 + len) return null;
    final frame = Uint8List.fromList(buffer.sublist(4, 4 + len));
    buffer.removeRange(0, 4 + len);
    return frame;
  }
}

/// Controlador Chromecast (Cast v2, porta 8009). Sem D-pad: o Cast não expõe
/// navegação de UI, apenas volume, mídia e apps.
class CastController extends BaseRemoteController {
  CastController(super.device, this.trust);

  final TlsTrust trust;

  static const _sender = 'sender-kremote';
  static const _receiver = 'receiver-0';

  SecureSocket? _socket;
  final _buffer = <int>[];
  Timer? _heartbeat;
  var _requestId = 1;
  Completer<void>? _ready;

  double _volume = 0.5;
  bool _muted = false;
  String? _transportId;
  String? _sessionId;
  int? _mediaSessionId;
  double _currentTime = 0;
  bool _playing = false;
  final Set<String> _connectedTransports = {};

  @override
  Set<RemoteKey> get supportedKeys => const {
    RemoteKey.power,
    RemoteKey.home,
    RemoteKey.back,
    RemoteKey.volumeUp,
    RemoteKey.volumeDown,
    RemoteKey.mute,
    RemoteKey.playPause,
    RemoteKey.play,
    RemoteKey.pause,
    RemoteKey.stop,
    RemoteKey.rewind,
    RemoteKey.fastForward,
    RemoteKey.next,
    RemoteKey.previous,
  };

  @override
  Set<RemoteCapability> get capabilities => const {RemoteCapability.appLaunch, RemoteCapability.volumeLevel};

  @override
  Future<void> connect() async {
    if (currentState == DeviceConnectionState.connected) return;
    if (_ready != null && !_ready!.isCompleted) return _ready!.future;
    _ready = Completer<void>();
    setState(DeviceConnectionState.connecting);
    try {
      await trust.load();
      // Fechado em _teardown() via _socket.destroy().
      // ignore: close_sinks
      final socket = await SecureSocket.connect(
        device.host,
        device.port,
        onBadCertificate: trust.accept,
        timeout: const Duration(seconds: 8),
      );
      await trust.commit();
      _socket = socket;
      socket.listen(
        _onData,
        onError: (Object e) => _teardown(DeviceConnectionState.error),
        onDone: () => _teardown(DeviceConnectionState.disconnected),
      );
      _send(_receiver, CastMessageCodec.nsConnection, {'type': 'CONNECT'});
      _connectedTransports.add(_receiver);
      _heartbeat = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _send(_receiver, CastMessageCodec.nsHeartbeat, {'type': 'PING'}),
      );
      _send(_receiver, CastMessageCodec.nsReceiver, {'type': 'GET_STATUS', 'requestId': _requestId++});
      await _ready!.future.timeout(
        const Duration(seconds: 8),
        onTimeout: () {
          throw const ConnectionException('Chromecast não respondeu ao status');
        },
      );
    } on HandshakeException {
      _teardown(DeviceConnectionState.error);
      throw _fail(TlsTrust.describeHandshakeFailure(hadPin: trust.hasPin));
    } catch (e) {
      _teardown(DeviceConnectionState.error);
      throw _fail(e is RemoteException ? e : ConnectionException(e.toString()));
    }
  }

  RemoteException _fail(RemoteException e) {
    final r = _ready;
    if (r != null && !r.isCompleted) {
      r.future.ignore();
      r.completeError(e);
    }
    return e;
  }

  void _send(String destination, String ns, Map<String, dynamic> payload) {
    _socket?.add(CastMessageCodec.encode(source: _sender, destination: destination, namespace: ns, payload: payload));
  }

  void _onData(Uint8List data) {
    _buffer.addAll(data);
    Uint8List? frame;
    while ((frame = CastMessageCodec.takeFrame(_buffer)) != null) {
      try {
        _handle(CastMessageCodec.decode(frame!));
      } catch (e) {
        log('frame inválido: $e');
      }
    }
  }

  void _handle(({String source, String destination, String namespace, Map<String, dynamic>? payload}) m) {
    final p = m.payload;
    if (p == null) return;
    final type = p['type'];
    if (m.namespace == CastMessageCodec.nsHeartbeat && type == 'PING') {
      _send(m.source, CastMessageCodec.nsHeartbeat, {'type': 'PONG'});
      return;
    }
    if (type == 'RECEIVER_STATUS') {
      final status = p['status'] as Map<String, dynamic>? ?? {};
      final vol = status['volume'] as Map<String, dynamic>?;
      if (vol != null) {
        _volume = (vol['level'] as num?)?.toDouble() ?? _volume;
        _muted = vol['muted'] as bool? ?? _muted;
      }
      final apps = status['applications'] as List<dynamic>? ?? [];
      if (apps.isNotEmpty) {
        final app = apps.first as Map<String, dynamic>;
        _sessionId = app['sessionId'] as String?;
        final transport = app['transportId'] as String?;
        if (transport != null && transport != _transportId) {
          _transportId = transport;
          if (!_connectedTransports.contains(transport)) {
            _send(transport, CastMessageCodec.nsConnection, {'type': 'CONNECT'});
            _connectedTransports.add(transport);
          }
          _send(transport, CastMessageCodec.nsMedia, {'type': 'GET_STATUS', 'requestId': _requestId++});
        }
      } else {
        _transportId = null;
        _sessionId = null;
        _mediaSessionId = null;
      }
      setState(DeviceConnectionState.connected);
      if (_ready != null && !_ready!.isCompleted) _ready!.complete();
    } else if (type == 'MEDIA_STATUS') {
      final list = p['status'] as List<dynamic>? ?? [];
      if (list.isNotEmpty) {
        final s = list.first as Map<String, dynamic>;
        _mediaSessionId = s['mediaSessionId'] as int?;
        _currentTime = (s['currentTime'] as num?)?.toDouble() ?? _currentTime;
        _playing = s['playerState'] == 'PLAYING' || s['playerState'] == 'BUFFERING';
      }
    } else if (type == 'CLOSE') {
      _connectedTransports.remove(m.source);
      if (m.source == _transportId) {
        _transportId = null;
        _mediaSessionId = null;
      }
    }
  }

  void _teardown(DeviceConnectionState next) {
    _heartbeat?.cancel();
    _heartbeat = null;
    _socket?.destroy();
    _socket = null;
    _buffer.clear();
    _connectedTransports.clear();
    _transportId = null;
    _mediaSessionId = null;
    setState(next);
  }

  @override
  Future<void> disconnect() async => _teardown(DeviceConnectionState.disconnected);

  void _setVolume({double? level, bool? muted}) {
    final vol = <String, dynamic>{};
    if (level != null) vol['level'] = level.clamp(0.0, 1.0);
    if (muted != null) vol['muted'] = muted;
    _send(_receiver, CastMessageCodec.nsReceiver, {'type': 'SET_VOLUME', 'requestId': _requestId++, 'volume': vol});
  }

  void _media(String type, [Map<String, dynamic> extra = const {}]) {
    final t = _transportId;
    if (t == null || _mediaSessionId == null) {
      throw const ProtocolException('Nenhuma mídia em reprodução no Chromecast');
    }
    _send(t, CastMessageCodec.nsMedia, {
      'type': type,
      'requestId': _requestId++,
      'mediaSessionId': _mediaSessionId,
      ...extra,
    });
  }

  void _stopApp() {
    if (_sessionId == null) return;
    _send(_receiver, CastMessageCodec.nsReceiver, {'type': 'STOP', 'requestId': _requestId++, 'sessionId': _sessionId});
  }

  @override
  Future<void> sendKey(RemoteKey key, {KeyPress press = KeyPress.short}) async {
    if (!supportedKeys.contains(key)) unsupported(key);
    if (press == KeyPress.longEnd) return;
    await ensureConnected();
    switch (key) {
      case RemoteKey.volumeUp:
        _setVolume(level: _volume + 0.05);
      case RemoteKey.volumeDown:
        _setVolume(level: _volume - 0.05);
      case RemoteKey.mute:
        _setVolume(muted: !_muted);
      case RemoteKey.playPause:
        _media(_playing ? 'PAUSE' : 'PLAY');
        _playing = !_playing;
      case RemoteKey.play:
        _media('PLAY');
        _playing = true;
      case RemoteKey.pause:
        _media('PAUSE');
        _playing = false;
      case RemoteKey.stop:
        _media('STOP');
      case RemoteKey.rewind:
        _media('SEEK', {'currentTime': (_currentTime - 10).clamp(0, double.infinity)});
      case RemoteKey.fastForward:
        _media('SEEK', {'currentTime': _currentTime + 10});
      case RemoteKey.next:
        _media('QUEUE_UPDATE', {'jump': 1});
      case RemoteKey.previous:
        _media('QUEUE_UPDATE', {'jump': -1});
      case RemoteKey.power || RemoteKey.home || RemoteKey.back:
        _stopApp();
      default:
        unsupported(key);
    }
  }

  @override
  Future<void> launchApp(AppShortcut app) async {
    final id = app.ids[device.protocol.name];
    if (id == null) throw UnsupportedError('App sem id Cast');
    await ensureConnected();
    _send(_receiver, CastMessageCodec.nsReceiver, {'type': 'LAUNCH', 'requestId': _requestId++, 'appId': id});
  }

  @override
  void dispose() {
    _teardown(DeviceConnectionState.disconnected);
    super.dispose();
  }
}
