/// Atalho de aplicativo (YouTube, Netflix…) mostrado no controle.
///
/// Cada protocolo resolve o identificador que precisa a partir de [ids].
class AppShortcut {
  const AppShortcut({required this.id, required this.label, required this.ids});

  /// Identificador interno (ex.: `youtube`).
  final String id;
  final String label;

  /// Identificadores por protocolo. Chaves: `androidTv` (deep link),
  /// `cast` (app id Cast), `samsungTizen`, `lgWebOs`, `roku`, `vizioSmartCast`.
  final Map<String, String> ids;

  static const youtube = AppShortcut(
    id: 'youtube',
    label: 'YouTube',
    ids: {
      'androidTv': 'https://www.youtube.com',
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
      'androidTv': 'https://www.netflix.com/title',
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
      'androidTv': 'https://app.primevideo.com',
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
      'androidTv': 'https://www.disneyplus.com',
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
      'androidTv': 'https://open.spotify.com',
      'cast': 'CC32E753',
      'samsungTizen': '3201606009684',
      'lgWebOs': 'spotify-beehive',
      'roku': '22297',
    },
  );

  static const globoplay = AppShortcut(
    id: 'globoplay',
    label: 'Globoplay',
    ids: {'androidTv': 'https://globoplay.globo.com', 'samsungTizen': '3201908019041', 'lgWebOs': 'globoplay'},
  );

  static const all = [youtube, netflix, primeVideo, disneyPlus, spotify, globoplay];
}
