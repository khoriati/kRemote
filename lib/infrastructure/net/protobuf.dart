import 'dart:convert';
import 'dart:typed_data';

/// Escritor protobuf mínimo (wire format), suficiente para os protocolos
/// Android TV Remote v2 e Cast v2 sem depender de código gerado.
class ProtoWriter {
  final BytesBuilder _b = BytesBuilder(copy: false);

  Uint8List toBytes() => _b.toBytes();

  void _tag(int field, int wireType) => varint((field << 3) | wireType);

  void varint(int value) {
    var v = value;
    while (v >= 0x80) {
      _b.addByte((v & 0x7f) | 0x80);
      v >>= 7;
    }
    _b.addByte(v);
  }

  void int32(int field, int value) {
    _tag(field, 0);
    // negativos são codificados em 10 bytes (two's complement 64 bits)
    varint(value < 0 ? value & 0xFFFFFFFFFFFFFFFF : value);
  }

  void bool_(int field, bool value) => int32(field, value ? 1 : 0);

  void bytes(int field, List<int> value) {
    _tag(field, 2);
    varint(value.length);
    _b.add(value);
  }

  void string(int field, String value) => bytes(field, utf8.encode(value));

  void message(int field, ProtoWriter inner) => bytes(field, inner.toBytes());

  /// Prefixa a mensagem com o tamanho em varint (framing Android TV Remote).
  static Uint8List frameVarint(Uint8List msg) {
    final w = ProtoWriter()..varint(msg.length);
    return Uint8List.fromList([...w.toBytes(), ...msg]);
  }
}

/// Campo decodificado.
class ProtoField {
  ProtoField(this.number, this.wireType, this.value);
  final int number;
  final int wireType;

  /// `int` para varint/fixed, `Uint8List` para length-delimited.
  final Object value;

  int get asInt => value as int;
  Uint8List get asBytes => value as Uint8List;
  String get asString => utf8.decode(asBytes);
  ProtoReader get asMessage => ProtoReader(asBytes);
}

/// Leitor protobuf mínimo.
class ProtoReader {
  ProtoReader(this._data);
  final Uint8List _data;
  int _pos = 0;

  bool get isDone => _pos >= _data.length;

  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (_pos >= _data.length) throw const FormatException('varint truncado');
      final b = _data[_pos++];
      result |= (b & 0x7f) << shift;
      if (b < 0x80) return result;
      shift += 7;
      if (shift > 63) throw const FormatException('varint inválido');
    }
  }

  ProtoField readField() {
    final key = readVarint();
    final number = key >> 3;
    final wireType = key & 7;
    switch (wireType) {
      case 0:
        return ProtoField(number, wireType, readVarint());
      case 1:
        final v = ByteData.sublistView(_data, _pos, _pos + 8).getUint64(0, Endian.little);
        _pos += 8;
        return ProtoField(number, wireType, v);
      case 2:
        final len = readVarint();
        if (_pos + len > _data.length) throw const FormatException('campo truncado');
        final bytes = Uint8List.sublistView(_data, _pos, _pos + len);
        _pos += len;
        return ProtoField(number, wireType, bytes);
      case 5:
        final v = ByteData.sublistView(_data, _pos, _pos + 4).getUint32(0, Endian.little);
        _pos += 4;
        return ProtoField(number, wireType, v);
      default:
        throw FormatException('wire type não suportado: $wireType');
    }
  }

  /// Lê todos os campos em um mapa (último valor vence; repetidos não são
  /// necessários nos protocolos usados).
  Map<int, ProtoField> readAll() {
    final out = <int, ProtoField>{};
    while (!isDone) {
      final f = readField();
      out[f.number] = f;
    }
    return out;
  }

  /// Tenta extrair um frame `varint(len) + payload` de [buffer].
  /// Retorna `null` se incompleto. Remove os bytes consumidos de [buffer].
  static Uint8List? takeVarintFrame(List<int> buffer) {
    var len = 0;
    var shift = 0;
    var i = 0;
    while (true) {
      if (i >= buffer.length) return null;
      final b = buffer[i++];
      len |= (b & 0x7f) << shift;
      if (b < 0x80) break;
      shift += 7;
    }
    if (buffer.length < i + len) return null;
    final frame = Uint8List.fromList(buffer.sublist(i, i + len));
    buffer.removeRange(0, i + len);
    return frame;
  }
}
