# Eko Nami

**Eko** — eco, o retorno da sua voz. **Nami** — 波, "onda" em japonês, a forma de onda
que pulsa no mic enquanto você fala. Duas palavras que qualquer língua pronuncia igual:
*e-ko na-mi*.

Ditado por voz para macOS, 100% local. Segure uma tecla, fale, solte — o texto aparece
onde o cursor estiver. Nada sai do Mac.

## Engines

| Engine | Modelo | Idiomas | Ao vivo |
| --- | --- | --- | --- |
| **Apple Local** (padrão) | SpeechAnalyzer do macOS 26+, Neural Engine | pt-BR / en-US | sim |
| **Parakeet** | NVIDIA Parakeet TDT 0.6B (CoreML via FluidAudio, ~470 MB) | V3: 25 idiomas, detecção automática · V2: inglês | não (lote, ~100× realtime) |
| **Whisper** | Catálogo WhisperKit CoreML, do tiny ao large-v3 | multilíngue (dica de idioma) | não (lote, VAD para áudios longos) |

Um modelo residente em RAM por vez. O card ENGINE mostra estado (disco/RAM),
latência medida do seu histórico (última, média, velocidade vs tempo real), barras
de progresso de download e — na pílula **↓** — tudo que está baixado, com tamanho
real e exclusão direta.

## Primeira execução

1. `make install` — compila, monta o `.app` e instala em /Applications.
2. **Acessibilidade**: Ajustes ▸ Privacidade e Segurança ▸ Acessibilidade → ativar.
   Necessária para a hotkey global e para colar o texto.
3. **Microfone**: o sistema pergunta na primeira gravação.
4. A primeira transcrição por idioma baixa o modelo de fala do sistema (uma vez).
5. Parakeet/Whisper: download explícito pelos botões do card ENGINE.

> O TCC ancora a permissão de Acessibilidade na assinatura de código. O Makefile
> assina com o primeiro Developer ID ou Apple Development do Keychain (por hash,
> nomes duplicados são ambíguos); só com assinatura ad-hoc é que cada rebuild
> derruba a permissão — desligue e ligue o app na lista de Acessibilidade.

## Uso

- **Hotkey** (padrão R⌥, modo segurar): configurável no card CONTROLES — presets ou
  qualquer tecla via "OUTRA…". Modo ALTERNAR: um toque liga, outro desliga.
- **HUD**: três tamanhos (mínimo / médio / grande), some no instante em que o texto
  cola. Transcrição ao vivo no engine Apple.
- **Dicionário**: correções determinísticas ("cloud code" → "Claude Code") + viés da
  engine. ~130 termos tech PT/EN de fábrica; adicione os seus no card
  (`ouvir → escrever`, Enter confirma; só `escrever` cria um termo de viés).
- **Histórico**: últimas 500 transcrições, busca, clique copia.
- **Dashboard**: grade bento — modo LAYOUT arrasta e redimensiona os seis tiles.
- **Menubar / Dock**: toggles no card CONTROLES (nunca ambos desligados).

## Apoie

Eko Nami é grátis e open source. Um café via Lightning é bem-vindo: menu da barra →
**Buy me a coffee** abre um QR (o endereço abreviado embaixo copia o LNURL inteiro).

## Build

SwiftPM puro, sem projeto Xcode. `make app` monta o bundle em
`~/Library/Caches/EkoNamiBuild` (fora de pastas sincronizadas — codesign odeia
file providers), `make run` roda, `make icon` regenera o ícone, `swift test` roda
os testes do corretor de dicionário.

Atualizando do Cochicho (nome anterior): histórico, dicionário, modelos Whisper e
ajustes migram sozinhos no primeiro launch; Acessibilidade e microfone precisam
ser concedidos de novo — o bundle id mudou e o TCC ancora na identidade.

## Licença

[MIT](LICENSE)

Arquitetura emprestada com gratidão de
[murmur-youtube](https://github.com/per-simmons/murmur-youtube) (captura de áudio,
event tap, injeção de texto verificada) — reescrita e estendida aqui.
