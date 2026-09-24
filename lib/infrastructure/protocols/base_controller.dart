import 'dart:async';

import 'package:meta/meta.dart';

import '../../domain/entities/connection_state.dart';
import '../../domain/entities/remote_device.dart';
import '../../domain/entities/remote_key.dart';
import '../../domain/errors.dart';
import '../../domain/ports/remote_controller.dart';
import '../net/log.dart';

/// Base com gestão de estado de conexão e logging para os adapters.
abstract class BaseRemoteController extends RemoteController {
  BaseRemoteController(this.device);

  @override
  final RemoteDevice device;

  final _stateCtrl = StreamController<DeviceConnectionState>.broadcast();
  DeviceConnectionState _state = DeviceConnectionState.disconnected;

  @override
  DeviceConnectionState get currentState => _state;

  @override
  Stream<DeviceConnectionState> get connectionState => Stream<DeviceConnectionState>.multi((c) {
    c.add(_state);
    final sub = _stateCtrl.stream.listen(c.add, onError: c.addError, onDone: c.close);
    c.onCancel = sub.cancel;
  });

  @protected
  void setState(DeviceConnectionState s) {
    if (_state == s) return;
    _state = s;
    log('estado → ${s.name}');
    if (!_stateCtrl.isClosed) _stateCtrl.add(s);
  }

  @protected
  void log(String msg) => KLog.d('${device.protocol.name}:${device.id}', msg);

  @protected
  Never unsupported(RemoteKey key) => throw UnsupportedKeyException(key);

  /// Garante conexão antes de enviar comandos.
  @protected
  Future<void> ensureConnected() async {
    if (_state == DeviceConnectionState.connected) return;
    await connect();
    if (_state != DeviceConnectionState.connected) {
      throw const ConnectionException('Não foi possível conectar ao dispositivo');
    }
  }

  @mustCallSuper
  void dispose() {
    _stateCtrl.close();
  }
}
