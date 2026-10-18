import 'dart:typed_data';

/// Porta de saída: captura de áudio do microfone para busca por voz.
///
/// O stream entrega PCM 16 bits, mono, 8 kHz, little-endian — o formato que
/// o Android TV Remote v2 aceita em `RemoteVoicePayload`.
abstract class VoiceSource {
  /// Pede a permissão de microfone ao sistema (se ainda não concedida).
  Future<bool> requestPermission();

  /// Inicia a captura. Chamar [stop] encerra o stream.
  Future<Stream<Uint8List>> start();

  Future<void> stop();
}
