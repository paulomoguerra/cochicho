# Eko Nami

**Eko** — eco, o retorno da sua voz. **Nami** — 波, "onda" em japonês, a forma de onda
que pulsa no mic enquanto você fala.

Ditado por voz 100% local para **macOS e Linux**. Segure uma tecla, fale, solte — o
texto aparece onde o cursor estiver. Nada sai da sua máquina.

Uma codebase só: core em Rust + UI web (Tauri 2). A versão original em Swift/SwiftUI
(macOS-only) está preservada em [`legacy-macos/`](legacy-macos/) como referência.

## Engines

| Engine | macOS | Linux | Ao vivo |
| --- | --- | --- | --- |
| **Apple Local** (SpeechAnalyzer) | sim (padrão) | — | sim |
| **Parakeet** TDT v2/v3 (sherpa-onnx, ONNX int8) | sim | sim | preview |
| **Whisper** (whisper.cpp, GGUF tiny→large-v3) | sim | sim | preview |

No Linux, o primeiro run pergunta qual engine você quer como padrão e baixa o modelo.

## Status

Em reescrita ativa (milestones M0–M6). Build e instruções por plataforma chegam no M6.

## Licença

[MIT](LICENSE)
