import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kremote/infrastructure/net/protobuf.dart';

void main() {
  group('ProtoWriter/ProtoReader', () {
    test('codifica e decodifica varint, string, bytes e mensagens aninhadas', () {
      final inner = ProtoWriter()
        ..int32(1, 622)
        ..string(2, 'kRemote');
      final w = ProtoWriter()
        ..int32(1, 2)
        ..int32(2, 200)
        ..int32(3, 300)
        ..bytes(4, [1, 2, 3])
        ..message(10, inner)
        ..bool_(11, true);
      final fields = ProtoReader(w.toBytes()).readAll();
      expect(fields[1]!.asInt, 2);
      expect(fields[2]!.asInt, 200);
      expect(fields[3]!.asInt, 300);
      expect(fields[4]!.asBytes, Uint8List.fromList([1, 2, 3]));
      expect(fields[11]!.asInt, 1);
      final nested = fields[10]!.asMessage.readAll();
      expect(nested[1]!.asInt, 622);
      expect(nested[2]!.asString, 'kRemote');
    });

    test('varint multi-byte', () {
      final w = ProtoWriter()..varint(300);
      expect(w.toBytes(), [0xAC, 0x02]);
      expect(ProtoReader(Uint8List.fromList([0xAC, 0x02])).readVarint(), 300);
    });

    test('framing varint extrai frames completos e mantém parciais', () {
      final a = (ProtoWriter()..int32(1, 1)).toBytes();
      final b = (ProtoWriter()..string(2, 'x' * 200)).toBytes(); // > 127 bytes → varint de 2 bytes
      final stream = [...ProtoWriter.frameVarint(a), ...ProtoWriter.frameVarint(b)];
      final buf = stream.sublist(0, stream.length - 5);
      expect(ProtoReader.takeVarintFrame(buf), a);
      expect(ProtoReader.takeVarintFrame(buf), isNull, reason: 'segundo frame incompleto');
      buf.addAll(stream.sublist(stream.length - 5));
      expect(ProtoReader.takeVarintFrame(buf), b);
      expect(buf, isEmpty);
    });

    test('rejeita varint truncado', () {
      expect(() => ProtoReader(Uint8List.fromList([0x80])).readVarint(), throwsFormatException);
    });
  });
}
