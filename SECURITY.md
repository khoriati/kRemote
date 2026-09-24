# Segurança

## Modelo de ameaças

| Ativo | Ameaça | Mitigação |
|---|---|---|
| Identidade do cliente Android TV (chave RSA) | Extração do aparelho / backup | Keychain / Keystore; `allowBackup=false`; regras de extração excluem dados |
| Tokens Samsung/Vizio, client-key LG, PSK Sony | Idem; vazamento em log | Armazenamento seguro; `KLog` nunca recebe segredos e só existe em debug |
| Conexão TLS com a TV | Interceptação por certificado forjado na LAN | Pinning SHA-256 por aparelho (TOFU); mudança de certificado bloqueia e alerta |
| Comandos HTTP em texto claro (Roku/Sony/Philips) | Sniffing/injeção na LAN | Limitação do fabricante; sem credenciais no tráfego (exceto PSK Sony, por design do fabricante); documentado |
| Entrada do usuário (host, porta, MAC, PIN, texto) | Injeção / abuso de URL | Validação estrita antes de compor URIs; `Uri()` estruturado, nunca concatenação |
| Descoberta (mDNS/SSDP) | Respostas maliciosas | Só metadados são usados para pré-preencher; a conexão exige emparelhamento/TLS pinado |
| Teclado Bluetooth HID | Computador não autorizado receber teclas | Só conecta a aparelhos previamente pareados no sistema; sem auto-conexão |

## Práticas

- Sem `Co-Authored-By`, sem segredos, `.env`, keystores ou perfis de
  provisionamento versionados (ver `.gitignore`).
- Release com `--obfuscate --split-debug-info`.
- Dependências revisadas e mínimas; atualize com `flutter pub outdated`.
- Rode `scripts/check.sh` e um scanner (ex.: Veracode/Trivy) antes de publicar.

## Reporte

Abra uma issue privada no repositório descrevendo o problema e os passos para
reproduzir. Não inclua credenciais ou endereços da sua rede.
