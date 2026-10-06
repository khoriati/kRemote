/// Atalho de aplicativo (YouTube, Netflix…) mostrado no controle.
///
/// Cada protocolo resolve o identificador que precisa a partir de [ids].
class AppShortcut {
  const AppShortcut({required this.id, required this.label, required this.ids});

  /// Identificador interno (ex.: `youtube`).
  final String id;
  final String label;

  /// Identificadores por protocolo. Chaves: `androidTv` (deep link `https://`
  /// ou `market://launch?id=<pacote>`; alternativas separadas por espaço são
  /// tentadas em ordem), `cast` (app id Cast), `samsungTizen`, `lgWebOs`,
  /// `roku`, `vizioSmartCast`.
  final Map<String, String> ids;

  /// Tile do app em `assets/apps/<id>.png` (gerado por `tool/gen_icons.sh`).
  String get asset => 'assets/apps/$id.png';

  static const youtube = AppShortcut(
    id: 'youtube',
    label: 'YouTube',
    ids: {
      'androidTv': 'https://www.youtube.com market://launch?id=com.google.android.youtube.tv',
      'cast': '233637DE',
      'samsungTizen': '111299001912',
      'lgWebOs': 'youtube.leanback.v4',
      'roku': '837',
      'sonyBravia': 'com.sony.dtv.com.google.android.youtube.tv',
    },
  );

  static const netflix = AppShortcut(
    id: 'netflix',
    label: 'Netflix',
    ids: {
      'androidTv': 'https://www.netflix.com/title market://launch?id=com.netflix.ninja',
      'cast': 'CA5E8412',
      'samsungTizen': '11101200001',
      'lgWebOs': 'netflix',
      'roku': '12',
      'sonyBravia': 'com.sony.dtv.com.netflix.ninja',
    },
  );

  static const primeVideo = AppShortcut(
    id: 'prime',
    label: 'Prime Video',
    ids: {
      'androidTv': 'https://app.primevideo.com market://launch?id=com.amazon.amazonvideo.livingroom',
      'cast': '17608BC8',
      'samsungTizen': '3201512006785',
      'lgWebOs': 'amazon',
      'roku': '13',
    },
  );

  static const disneyPlus = AppShortcut(
    id: 'disney',
    label: 'Disney+',
    ids: {
      'androidTv': 'https://www.disneyplus.com market://launch?id=com.disney.disneyplus',
      'cast': 'C3DE6BC2',
      'samsungTizen': '3201901017640',
      'lgWebOs': 'com.disney.disneyplus-prod',
      'roku': '291097',
    },
  );

  static const spotify = AppShortcut(
    id: 'spotify',
    label: 'Spotify',
    ids: {
      'androidTv': 'https://open.spotify.com market://launch?id=com.spotify.tv.android',
      'cast': 'CC32E753',
      'samsungTizen': '3201606009684',
      'lgWebOs': 'spotify-beehive',
      'roku': '22297',
    },
  );

  static const globoplay = AppShortcut(
    id: 'globoplay',
    label: 'Globoplay',
    // O app da Globo na TV não trata o link do site; abre pelo pacote.
    ids: {
      'androidTv': 'market://launch?id=com.globo.globotv https://globoplay.globo.com',
      'samsungTizen': '3201908019041',
      'lgWebOs': 'globoplay',
    },
  );

  static const max = AppShortcut(
    id: 'max',
    label: 'Max',
    ids: {'androidTv': 'https://play.max.com market://launch?id=com.wbd.stream'},
  );

  static const appleTv = AppShortcut(
    id: 'appletv',
    label: 'Apple TV',
    ids: {
      'androidTv':
          'https://tv.apple.com market://launch?id=com.wbd.stream market://launch?id=com.apple.atve.androidtv.appletv',
    },
  );

  static const paramountPlus = AppShortcut(
    id: 'paramountplus',
    label: 'Paramount+',
    ids: {
      'androidTv':
          'https://www.paramountplus.com market://launch?id=com.wbd.stream market://launch?id=com.apple.atve.androidtv.appletv market://launch?id=com.cbs.ott',
    },
  );

  static const crunchyroll = AppShortcut(
    id: 'crunchyroll',
    label: 'Crunchyroll',
    ids: {'androidTv': 'https://www.crunchyroll.com market://launch?id=com.crunchyroll.crunchyroid'},
  );

  static const all = [
    youtube,
    netflix,
    primeVideo,
    disneyPlus,
    max,
    globoplay,
    spotify,
    appleTv,
    paramountPlus,
    crunchyroll,
  ];
}
