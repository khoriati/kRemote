import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kremote/infrastructure/protocols/cast/cast_controller.dart';

void main() {
  group('CastMessageCodec', () {
    test('roundtrip com framing de 4 bytes big-endian', () {
      final bytes = CastMessageCodec.encode(
        source: 'sender-0',
        destination: 'receiver-0',
        namespace: CastMessageCodec.nsReceiver,
        payload: {'type': 'GET_STATUS', 'requestId': 1},
      );
      final len = ByteData.sublistView(bytes, 0, 4).getUint32(0, Endian.big);
      expect(len, bytes.length - 4);
      final buf = bytes.toList();
      final frame = CastMessageCodec.takeFrame(buf)!;
      expect(buf, isEmpty);
      final m = CastMessageCodec.decode(frame);
      expect(m.source, 'sender-0');
      expect(m.destination, 'receiver-0');
      expect(m.namespace, CastMessageCodec.nsReceiver);
      expect(m.payload?['type'], 'GET_STATUS');
    });

    test('takeFrame aguarda frame completo', () {
      final bytes = CastMessageCodec.encode(source: 'a', destination: 'b', namespace: 'c', payload: {'x': 1});
      final buf = bytes.sublist(0, bytes.length - 1).toList();
      expect(CastMessageCodec.takeFrame(buf), isNull);
      buf.add(bytes.last);
      expect(CastMessageCodec.takeFrame(buf), isNotNull);
    });
  });
}
