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

## Conexão resiliente e presença na rede

- **IP mudou (roteador reiniciado, troca de Wi-Fi da TV ou do celular)**: o
  aparelho fica cadastrado com o nome da instância mDNS/SSDP (`serviceName`).
  Quando o endereço gravado não responde, o app procura o serviço na rede e,
  se ele reapareceu em outro IP, atualiza o cadastro no lugar — mesmo `id`,
  mesmas credenciais e mesmo pin TLS; não é preciso remover e emparelhar de
  novo. Cadastros antigos (sem `serviceName`) casam pelo nome amigável.
- **Ao abrir o app / voltar do segundo plano**: o aparelho ativo é reconectado
  automaticamente. Se não for encontrado, abre-se a lista de *Aparelhos
  disponíveis* (cadastrados com presença + novos encontrados na rede).
- **Heartbeat**: enquanto uma lista de aparelhos está na tela (*Meus
  dispositivos*, *Aparelhos disponíveis*, *Adicionar dispositivo*), a
  presença dos cadastrados é verificada a cada 5 s (TCP) e a busca
  mDNS/SSDP se repete a cada 10 s (`NetworkScanner`), sumindo com quem não é
  visto há 25 s. Aparelhos fora da rede disparam uma relocalização (no máximo
  a cada 20 s).
- **Emparelhamento**: um único fluxo por vez (a tela de controle só abre o
  emparelhamento quando está em primeiro plano) e o sucesso é registrado
  antes de a TV fechar o socket — o fechamento não é mais tratado como falha.

## Apps

O painel *Apps* mostra tiles com ícone. Na Google TV / Android TV o protocolo de
controle não lista os apps instalados; a verificação usa o canal Cast do mesmo
aparelho (`GET_APP_AVAILABILITY`), que na Google TV reflete o app Android
instalado. Atalhos sem id Cast (Max, Apple TV, Paramount+, Crunchyroll,
Globoplay) não são verificáveis e ficam sempre visíveis; "Mostrar todos"
revela os ocultos. Na Google TV cada atalho pode ter mais de um alvo
(URL ou nome de pacote, separados por espaço): se a TV responde `remote_error`
ao primeiro, o próximo é tentado — o Globoplay abre pelo pacote
`com.globo.globotv`, pois não trata o link do site. Os tiles ficam em `assets/apps` e são gerados por
`tool/gen_icons.sh` a partir de `assets/apps/src/*.svg` (glifos CC0 do Simple
Icons quando existem; monograma nas cores da marca para os demais).

## Teclado e voz

O painel *Teclado* tem modos **ABC** e **123** com envio tecla a tecla
(`KEYCODE_A`…`Z`, dígitos e símbolos), o mesmo caminho do painel Números, que
funciona em qualquer campo da TV. Abaixo há um campo para enviar uma frase
inteira: se a TV anunciou um campo de texto em foco, usa o canal IME; senão,
cai em teclas (acentos não têm tecla e são ignorados).

O botão de microfone envia `KEYCODE_ASSIST`, que só ativa o Assistente na TV.
O áudio do celular **não** é transmitido: o protocolo Android TV Remote v2 tem
mensagens de voz, mas o formato do áudio não é documentado e nenhum cliente
aberto o implementa.

## Ícone do app

`assets/icon/app_icon.svg` é a fonte; `tool/gen_icons.sh` (requer `librsvg` e
`imagemagick`) gera o *appiconset* do iOS e os `mipmap` do Android, incluindo
o ícone adaptativo (`mipmap-anydpi-v26`).

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
│   │                       (NetworkScanner, em application/, compartilha e repete a busca)
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
- **Log estruturado** (`KLog`) apenas em debug, sem tokens, PINs ou certificados;
  a tela Diagnóstico exporta o log pela folha de compartilhamento (AirDrop,
  Mail…), pois a área de transferência universal iPhone→Mac não é confiável.
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
| `scripts/deploy-ios.sh [id]` | deploy release (sem debug) no iPhone por USB/Wi-Fi; instala por cima via `devicectl`, preservando cadastros e emparelhamentos |
| `scripts/deploy-android.sh [id]` | deploy release (sem debug) no Android por USB; `adb install -r`, preservando cadastros e emparelhamentos |
| `scripts/dev.sh run\|devices\|probe\|clean` | atalhos de desenvolvimento |
| `tool/gen_icons.sh` | regenera ícone do app (iOS/Android) e tiles dos apps |

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
