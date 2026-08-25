# Eko Nami

**Eko** — eco, o retorno da sua voz. **Nami** — 波, "onda" em japonês, a forma de onda
que pulsa no mic enquanto você fala.

Ditado por voz 100% local. Segure uma tecla, fale, solte — o texto aparece onde o
cursor estiver. Nada sai da sua máquina.

Uma codebase só (Rust + React via Tauri 2) que **compila nativamente no OS em que
você está**. No macOS você gera o app macOS; no Linux, o pacote Linux. Não existe
um “app Linux embutido no macOS” nem o contrário — escolha a seção do **seu**
sistema abaixo e ignore a outra.

A versão original em Swift/SwiftUI (macOS-only) está em [`legacy-macos/`](legacy-macos/)
como referência.

## Engines

| Engine | macOS | Linux | Notas |
| --- | --- | --- | --- |
| **Apple Local** (SpeechAnalyzer) | sim (**padrão**) | — | só Apple Silicon / macOS recente |
| **Parakeet** TDT v2/v3 | sim | sim | stub por enquanto (sherpa-onnx real ainda pendente) |
| **Whisper** (whisper.cpp, GGUF) | sim | sim (**recomendado no Linux**) | CPU; tiny → large-v3 |

No Linux, o primeiro run pergunta qual engine usar e baixa o modelo. No macOS o
padrão é Apple; Whisper/Parakeet ficam opcionais nas settings.

---

## Requisitos comuns (os dois)

- [Node.js](https://nodejs.org/) 20+
- [Rust](https://rustup.rs/) stable (`rustup` + `cargo`)
- Git

```bash
git clone https://github.com/paulomoguerra/eko-nami.git
cd eko-nami
npm install
```

Depois disso, siga **só** a seção do seu OS.

---

## macOS

Gera `.app` / `.dmg`. **Não** baixa nem empacota nada de Linux.

### Dependências

- Xcode Command Line Tools (`xcode-select --install`)
- macOS recente o bastante pro SpeechAnalyzer (Apple Local)

### Dev

```bash
npm run tauri dev
```

Dados de debug vão em `~/Library/Application Support/EkoNami-dev/` (isolados do
app de produção em `EkoNami/`).

### Build / instalar

```bash
npm run tauri build
```

Artefatos (só macOS):

- `src-tauri/target/release/bundle/macos/Eko Nami.app`
- `src-tauri/target/release/bundle/dmg/Eko Nami_*.dmg`

Abra o `.app` ou monte o `.dmg`. Na primeira execução o macOS pede **Microfone** e
**Acessibilidade** (colar texto no app em foco).

### Engine padrão

Apple Local. Não precisa baixar modelo pra começar. Whisper/Parakeet são opcionais
no dashboard.

---

## Linux

Gera `.deb` / `.rpm` / AppImage. **Não** precisa (nem consegue) gerar o `.app`
macOS daqui.

Testado em Ubuntu 24.04; as deps abaixo cobrem Debian/Ubuntu. Em Fedora/Arch use
os pacotes equivalentes (webkitgtk, gtk3, alsa, rsvg, appindicator).

### Dependências (Debian/Ubuntu)

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential curl wget file \
  libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev \
  libasound2-dev clang libclang-dev pkg-config cmake
```

### Permissões de hotkey + colar texto

O hotkey lê `/dev/input/event*` (grupo `input`). A injeção de texto usa
`/dev/uinput`.

```bash
sudo usermod -aG input "$USER"
# relogue (ou reinicie a sessão gráfica) depois disso

echo 'KERNEL=="uinput", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput"' \
  | sudo tee /etc/udev/rules.d/99-ekonami-uinput.rules
sudo udevadm control --reload-rules
sudo udevadm trigger
sudo modprobe uinput
```

Sem o grupo `input` o app sobe, mas o hotkey global não funciona.

### Dev

```bash
npm run tauri dev
```

Dados em `~/.local/share/ekonami-dev/` (dev) ou `~/.local/share/ekonami/` (release).

### Build / instalar

```bash
npm run tauri build
```

Artefatos (só Linux):

- `src-tauri/target/release/bundle/deb/Eko Nami_*_amd64.deb`
- `src-tauri/target/release/bundle/rpm/Eko Nami-*.rpm`
- `src-tauri/target/release/bundle/appimage/Eko Nami_*_amd64.AppImage`

Ubuntu/Debian:

```bash
sudo dpkg -i src-tauri/target/release/bundle/deb/Eko\ Nami_*_amd64.deb
ekonami
```

### Engine padrão

No primeiro run o app mostra o picker. **Use Whisper** (tiny ou base) pra testar
ditado de verdade — Parakeet ainda é stub e não transcreve.

---

## O que *não* fazer

| Em… | Não faça |
| --- | --- |
| macOS | Não espere `.deb` / AppImage; o bundler só emite `.app`/`.dmg` |
| Linux | Não espere `.app`/`.dmg`; o bundler só emite deb/rpm/AppImage |
| Qualquer um | Não precisa clonar duas vezes nem “carregar o app do outro OS” |

Cross-compile mac↔Linux **não** está no escopo: compile na máquina (ou CI) do
mesmo OS que vai rodar.

---

## Status

- M0–M4: scaffold, Linux e2e (Whisper), dashboard, backends macOS — feitos
- Parakeet real (`sherpa-onnx`): pendente
- M5 polish (tray, sons, wizards) e M6 packaging assinado / CI: pendentes

## Licença

[MIT](LICENSE)
