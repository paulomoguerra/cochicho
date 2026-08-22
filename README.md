# Cochicho

Ditado por voz para macOS, 100% local. Segure uma tecla, fale, solte — o texto aparece
onde o cursor estiver. Nada sai do Mac.

## Engines

| Engine | Modelo | Idiomas | Live preview |
| --- | --- | --- | --- |
| **Apple Local** (padrão) | SpeechAnalyzer do macOS 26+, Neural Engine | pt-BR / en-US (seleção manual) | sim |
| **Parakeet V3** | NVIDIA Parakeet TDT 0.6B (CoreML via FluidAudio, ~470 MB do Hugging Face) | 25 idiomas, detecção automática | não (batch, ~100× realtime) |

## Primeira execução

1. `make install` — compila, monta o `.app` e instala em /Applications.
2. **Acessibilidade**: Ajustes ▸ Privacidade e Segurança ▸ Acessibilidade → ativar
   Cochicho. Necessária para a hotkey global e para colar o texto.
3. **Microfone**: o sistema pergunta na primeira gravação.
4. A primeira transcrição por idioma baixa o modelo de fala do sistema (rápido, uma vez).
5. Parakeet: botão "Baixar modelo" no card ENGINE (opcional).

> Assinatura ad-hoc: a cada `make install` o macOS invalida silenciosamente a permissão
> de Acessibilidade (o TCC ancora na assinatura). Se a hotkey parar após um rebuild,
> desligue e ligue o Cochicho na lista de Acessibilidade. Com um Developer ID no
> Keychain o Makefile o usa automaticamente e o problema some.

## Uso

- **Hotkey** (padrão R⌥, modo segurar): configurável no card CONTROLES — presets ou
  qualquer tecla via "OUTRA…". Modo ALTERNAR: um toque liga, outro desliga.
- **Dicionário**: correções determinísticas ("cloud code" → "Claude Code") + viés da
  engine. Pré-populado com ~130 termos tech PT/EN. `ouvir → escrever`; só `escrever`
  cria um termo de viés.
- **Histórico**: últimas 500 transcrições, busca, clique copia.
- **Menubar / Dock**: toggles no card CONTROLES (nunca ambos desligados).

## Build

SwiftPM puro, sem projeto Xcode. `make app` monta o bundle em
`~/Library/Caches/CochichoBuild` (fora de pastas sincronizadas — codesign odeia
file providers), `make run` roda, `make icon` regenera o ícone.

Arquitetura emprestada com gratidão de
[murmur-youtube](https://github.com/per-simmons/murmur-youtube) (captura de áudio,
event tap, injeção de texto verificada) — reescrita e estendida aqui.

## Apoie

Cochicho é grátis e open source. Se ele ganhou lugar no seu Mac, um café via
Lightning é bem-vindo: menu da barra → **Buy me a coffee** (abre na carteira ou
copia o LNURL).

## Licença

[MIT](LICENSE)
