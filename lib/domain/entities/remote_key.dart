/// Teclas abstratas de um controle remoto convencional.
///
/// Cada protocolo mapeia estas teclas para seus próprios códigos. O conjunto
/// cobre integralmente o controle do Chromecast com Google TV e acrescenta as
/// teclas usuais de TVs de mercado (canais, numérico, mídia, cores).
enum RemoteKey {
  // Núcleo do controle Chromecast
  power,
  input,
  assistant,
  back,
  home,
  up,
  down,
  left,
  right,
  ok,
  volumeUp,
  volumeDown,
  mute,

  // Mídia
  playPause,
  play,
  pause,
  stop,
  rewind,
  fastForward,
  next,
  previous,
  record,

  // TV
  channelUp,
  channelDown,
  menu,
  info,
  guide,
  settings,
  exit,
  captions,

  // Numérico
  num0,
  num1,
  num2,
  num3,
  num4,
  num5,
  num6,
  num7,
  num8,
  num9,
  dash,
  backspace,
  enter,

  // Cores
  red,
  green,
  yellow,
  blue,

  // Letras (teclado do controle, tecla a tecla)
  letterA,
  letterB,
  letterC,
  letterD,
  letterE,
  letterF,
  letterG,
  letterH,
  letterI,
  letterJ,
  letterK,
  letterL,
  letterM,
  letterN,
  letterO,
  letterP,
  letterQ,
  letterR,
  letterS,
  letterT,
  letterU,
  letterV,
  letterW,
  letterX,
  letterY,
  letterZ,
  space;

  bool get isDigit => index >= num0.index && index <= num9.index;

  /// Dígito correspondente (0–9) quando [isDigit].
  int get digit => isDigit ? index - num0.index : -1;

  static RemoteKey fromDigit(int d) {
    assert(d >= 0 && d <= 9);
    return RemoteKey.values[num0.index + d];
  }

  bool get isLetter => index >= letterA.index && index <= letterZ.index;

  /// Letra minúscula correspondente quando [isLetter] (`' '` para [space]).
  String get char => isLetter
      ? String.fromCharCode(0x61 + index - letterA.index)
      : this == space
      ? ' '
      : '';

  /// Tecla da letra `a`–`z` (qualquer caixa); `null` para outros caracteres.
  static RemoteKey? fromLetter(String ch) {
    if (ch.length != 1) return null;
    final c = ch.toLowerCase().codeUnitAt(0);
    if (c < 0x61 || c > 0x7a) return null;
    return RemoteKey.values[letterA.index + c - 0x61];
  }
}

/// Tipo de pressionamento de uma tecla.
enum KeyPress { short, longStart, longEnd }
