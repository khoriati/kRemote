# kRemote

Controle remoto universal em Flutter para Android e iOS. Controla integralmente
**Google TV / Android TV** (Chromecast com Google TV, Philips, Sony, TCL…) e
Chromecast clássico, além de Samsung, LG, Roku, Sony Bravia, Philips JointSpace e
Vizio. No Android, também transforma o celular em **teclado Bluetooth** para
comandar apresentações e volume em PC/Mac.

Vários aparelhos da casa ficam cadastrados ao mesmo tempo; a troca é feita no
seletor do topo da tela, com um controlador vivo por aparelho.

## Protocolos suportados

| Protocolo | Aparelhos | Transporte | Emparelhamento | D-pad | Volume | Mídia | Apps | Texto |
|---|---|---|---|---|---|---|---|---|
| Android TV Remote v2 | Google TV, Chromecast com Google TV, Android TV | TLS mútuo 6466/6467 (protobuf) | PIN na TV | ✔ | ✔ | ✔ | ✔ | ✔ |
| Cast v2 | Chromecast clássico, Nest Hub | TLS 8009 (protobuf) | — | — | ✔ | ✔ | ✔ | — |
| Samsung Tizen | Smart TV 2016+ | WSS 8002 | Aceitar na TV (token) | ✔ | ✔ | ✔ | ✔ | ✔ |
| LG webOS | Smart TV webOS | WS 3000 / WSS 3001 (SSAP) | Aceitar na TV (client-key) | ✔ | ✔ | ✔ | ✔ | — |
| Roku ECP | Roku TV / players | HTTP 8060 | — | ✔ | ✔ | ✔ | ✔ | ✔ |
| Sony Bravia IRCC | Bravia | HTTP 80 (SOAP + REST) | Pre-Shared Key | ✔ | ✔ | ✔ | ✔ | — |
| Philips JointSpace | Philips não-Android | HTTP 1925 (v1/v5) | — | ✔ | ✔ | ✔ | — | — |
| Vizio SmartCast | Vizio | HTTPS 7345/9000 | PIN na TV | ✔ | ✔ | ✔ | ✔ | — |
| Bluetooth HID | PC / Mac (Android apenas) | Bluetooth Classic HID | Pareamento do sistema | ✔ (setas) | ✔ | ✔ | — | ✔ |

TVs Philips **com Google TV** devem ser adicionadas como *Google TV / Android TV*
(o app já as descobre assim); JointSpace é só para Philips sem Android.

## Arquitetura

Ports-and-adapters (hexagonal). O domínio não conhece Flutter nem rede.

```
lib/
├── domain/                 entidades (RemoteKey, RemoteDevice, AppShortcut) e ports
│   └── ports/              RemoteController, PairingFlow, DeviceDiscovery, stores
├── application/            casos de uso: DeviceService, SettingsService, validação
├── infrastructure/
│   ├── protocols/          um adapter por protocolo (+ base_controller)
│   ├── discovery/          Bonjour/NSD nativo (nsd) e SSDP; agregador composto
│   ├── net/                protobuf mínimo, TlsTrust (pinning), WoL, log
│   ├── storage/            SharedPreferences (dispositivos) e Keychain/Keystore
│   └── controller_factory  monta adapter + credenciais + política TLS
├── presentation/           telas e widgets (D-pad, botões, seletor de aparelho)
└── app/                    tema (claro/escuro/alto contraste), DI (AppScope)
```

Toda tecla é um `RemoteKey` abstrato; cada adapter declara `supportedKeys`, e a
UI desabilita o que o protocolo não oferece. Protobuf é codificado à mão
(`net/protobuf.dart`) para evitar código gerado e dependências extras.

## Segurança

Projetado para passar em análise estática (SAST) e revisão de arquitetura:

- **TLS com pinning (TOFU)**: certificados autoassinados das TVs são aceitos só
  no primeiro uso e a impressão digital SHA-256 fica fixada por aparelho
  (`TlsTrust`). Um certificado diferente é recusado com aviso explícito; a
  confiança só é redefinida por ação do usuário. Não há `badCertificateCallback`
  que aceite tudo.
- **Credenciais só em armazenamento seguro** (Keychain / Android Keystore):
  certificado e chave RSA do cliente Android TV, tokens Samsung/Vizio,
  client-key LG e PSK Sony. Nunca em SharedPreferences, logs ou backups
  (`allowBackup=false`, regras de extração excluem tudo).
- **Sem segredos no código**. A única constante longa é a assinatura pública do
  manifesto de desenvolvimento da LG, exigida pelo webOS e distribuída pela
  própria LG em todos os clientes SSAP abertos.
- **Validação de entrada**: host (IPv4/IPv6/hostname RFC 1123), porta, MAC, PIN
  (6 hex / 4 dígitos) e tamanho de texto. IDs de dispositivo são derivados e
  saneados.
- **Log estruturado** (`KLog`) apenas em debug, sem tokens, PINs ou certificados.
- **Tráfego em texto claro** existe apenas onde o fabricante não oferece TLS
  (Roku, Sony, Philips), restrito à LAN e documentado em
  `network_security_config.xml`; no iOS usa-se `NSAllowsLocalNetworking`,
  não `NSAllowsArbitraryLoads`.
- **Dependências mínimas**: `basic_utils`/`pointycastle` (certificado RSA),
  `crypto`, `http`, `nsd`, `shared_preferences`, `flutter_secure_storage`.
- Builds release com `--obfuscate` e `--split-debug-info` (ver `scripts/`).

Consulte `SECURITY.md` para o modelo de ameaças e como reportar.

## Pré-requisitos por plataforma

### iOS (iPhone 14 testado)
Já configurado em `ios/Runner/Info.plist`:
- `NSLocalNetworkUsageDescription` e `NSBonjourServices`
  (`_androidtvremote2._tcp`, `_googlecast._tcp`, `_viziocast._tcp`) — a
  descoberta usa Bonjour nativo e **não** exige a entitlement de multicast.
- `NSAppTransportSecurity › NSAllowsLocalNetworking`.
- Orientação retrato; `ITSAppUsesNonExemptEncryption = false`.

Limitações do iOS: SSDP (Samsung/LG/Roku/Sony/Philips) depende de UDP multicast
e requer a entitlement `com.apple.developer.networking.multicast` (aprovação da
Apple); sem ela, adicione esses aparelhos por IP. Teclado Bluetooth HID não é
permitido pela Apple e fica oculto.

Primeira execução: `scripts/build-ios.sh setup` (Xcode para escolher a
equipe de assinatura), depois `scripts/build-ios.sh run`.

### Android (Moto G50 / Android 11 testado)
- `minSdk 28` (necessário ao `BluetoothHidDevice`).
- Permissões: rede local/multicast, `BLUETOOTH_CONNECT`/`ADVERTISE` (pedidas em
  tempo de execução pelo código nativo, sem plugin de terceiros).
- `scripts/build-android.sh install` compila e instala no aparelho via USB.

## Scripts

| Script | Uso |
|---|---|
| `scripts/check.sh [--coverage]` | formatação + `flutter analyze --fatal-infos` + testes |
| `scripts/build-android.sh debug\|release\|bundle\|install` | APK/AAB; assina release com `KEYSTORE_*` do ambiente |
| `scripts/build-ios.sh setup\|run\|device\|ipa\|archive-nosign` | pods, rodar no iPhone, IPA (`IOS_TEAM_ID`, `IOS_EXPORT_METHOD`) |
| `scripts/dev.sh run\|devices\|probe\|clean` | atalhos de desenvolvimento |

Artefatos vão para `build/dist/{android,ios}`, nomeados pela versão do `pubspec`.

## Testes

```bash
scripts/check.sh
```

A suíte cobre o codec protobuf, geração de certificado (aceito pelo
`SecurityContext`), cálculo do segredo de emparelhamento, mapas de teclas de
todos os protocolos, `TlsTrust`, Wake-on-LAN, validação de entrada, o serviço de
dispositivos e widgets (D-pad, temas, troca de aparelho). O caminho crítico
Android TV é exercitado **ponta a ponta** contra servidores falsos com TLS mútuo
(`test/support/fake_android_tv.dart`): emparelhamento completo com PIN,
rejeição de PIN errado, detecção de certificado alterado, handshake
configure/set_active/ping, injeção de teclas e abertura de apps.

### Validação com aparelhos reais
`tool/atv_probe.dart` valida o protocolo contra uma TV real sem o app:

```bash
dart run tool/atv_probe.dart <ip> probe        # TLS + PairingRequest/Ack
dart run tool/atv_probe.dart <ip> pair         # emparelha (pede o PIN da TV)
dart run tool/atv_probe.dart <ip> key mute     # envia tecla
```

No macOS 15+, o binário `dart` precisa da permissão **Rede local** (Ajustes ›
Privacidade e Segurança › Rede local) para o terminal em uso; sem ela, o
`tool/atv_frames.dart` gera os frames e o handshake pode ser feito com
`openssl s_client -cert cert.pem -key key.pem`.

## Roadmap
- Apple TV (Companion/MRP) e Fire TV (ADB) — protocolos pesados, fora do MVP.
- Entrada de texto Android TV via IME (hoje usa eventos de tecla, minúsculas).
- Emissor infravermelho em celulares que o possuem.
- Widgets/atalhos de tela inicial por aparelho.
