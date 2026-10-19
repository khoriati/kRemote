import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import '../../domain/ports/voice_source.dart';
import '../net/log.dart';

/// Microfone do celular via `record`, entregue como PCM16 mono 8 kHz.
///
/// Grava a 16 kHz (taxa que todo celular suporta) e reduz pela metade com a
/// média de pares de amostras, como faz o app Google TV.
class MicrophoneVoiceSource implements VoiceSource {
  MicrophoneVoiceSource({AudioRecorder? recorder}) : _injected = recorder;

  final AudioRecorder? _injected;
  AudioRecorder? _lazy;

  /// Criado só no primeiro uso: o construtor do plugin abre o canal nativo.
  AudioRecorder get _recorder => _injected ?? (_lazy ??= AudioRecorder());
  StreamSubscription<Uint8List>? _sub;
  StreamController<Uint8List>? _out;
  final _carry = <int>[];

  static const captureRate = 16000;
  static const targetRate = 8000;

  @override
  Future<bool> requestPermission() => _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> start() async {
    await stop();
    final out = StreamController<Uint8List>();
    _out = out;
    _carry.clear();
    final raw = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: captureRate,
        numChannels: 1,
        autoGain: true,
        noiseSuppress: true,
      ),
    );
    _sub = raw.listen(
      (chunk) {
        final data = downsampleHalf(chunk, _carry);
        if (data.isNotEmpty && !out.isClosed) out.add(data);
      },
      onError: (Object e) {
        KLog.d('voice', 'erro de captura: $e');
        if (!out.isClosed) out.addError(e);
      },
      onDone: () {
        if (!out.isClosed) out.close();
      },
    );
    return out.stream;
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    try {
      if (_injected != null || _lazy != null) {
        if (await _recorder.isRecording()) await _recorder.stop();
      }
    } catch (e) {
      KLog.d('voice', 'parar captura: $e');
    }
    final out = _out;
    _out = null;
    if (out != null && !out.isClosed) await out.close();
  }

  /// Reduz PCM16 little-endian de 16 kHz para 8 kHz pela média de cada par
  /// de amostras. [carry] guarda bytes de uma amostra/par incompletos entre
  /// chamadas, para não perder nem desalinhar amostras.
  static Uint8List downsampleHalf(Uint8List chunk, List<int> carry) {
    final all = carry.isEmpty ? chunk : Uint8List.fromList([...carry, ...chunk]);
    carry.clear();
    final usable = all.length - (all.length % 4);
    if (usable < all.length) carry.addAll(all.sublist(usable));
    final src = ByteData.sublistView(all, 0, usable);
    final out = ByteData(usable ~/ 2);
    for (var i = 0, o = 0; i < usable; i += 4, o += 2) {
      final a = src.getInt16(i, Endian.little);
      final b = src.getInt16(i + 2, Endian.little);
      out.setInt16(o, ((a + b) / 2).round().clamp(-32768, 32767), Endian.little);
    }
    return out.buffer.asUint8List();
  }
}
