//! Port de `DictionaryEntry.swift` + `DictionaryStore.swift` + `DefaultDictionary.swift`.
//! O dicionário do usuário persiste como JSON; na primeira execução é semeado com o
//! vocabulário padrão (~130 termos tech PT/EN). Depois disso o arquivo é a verdade.

use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::RwLock;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::core::corrector::DictionaryCorrector;
use crate::core::persist::DiskPersister;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EntryKind {
    /// Palavra que a engine deve conhecer — alimenta só o viés.
    Term,
    /// "ouve X, escreve Y" — alimenta viés (em Y) e a correção determinística (X → Y).
    Correction,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct DictionaryEntry {
    pub id: Uuid,
    pub kind: EntryKind,
    /// O texto correto — o que é escrito e para o que a engine é enviesada.
    pub write: String,
    /// Só para correção: o X de "quando ouvir X". Vazio para termo.
    #[serde(default)]
    pub hear: String,
    /// Alias `isEnabled` — o JSON do app Swift usa camelCase.
    #[serde(default = "default_true", alias = "isEnabled")]
    pub is_enabled: bool,
}

fn default_true() -> bool {
    true
}

impl DictionaryEntry {
    pub fn term(word: &str) -> Self {
        Self {
            id: Uuid::new_v4(),
            kind: EntryKind::Term,
            write: word.to_string(),
            hear: String::new(),
            is_enabled: true,
        }
    }

    pub fn correction(hear: &str, write: &str) -> Self {
        Self {
            id: Uuid::new_v4(),
            kind: EntryKind::Correction,
            write: write.to_string(),
            hear: hear.to_string(),
            is_enabled: true,
        }
    }
}

/// Uma correção que de fato disparou — guardada para o histórico mostrar se o
/// dicionário está valendo seu lugar.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct AppliedCorrection {
    pub from: String,
    pub to: String,
    pub count: usize,
}

pub struct DictionaryStore {
    entries: RwLock<Vec<DictionaryEntry>>,
    /// Reconstruído preguiçosamente quando entries mudam — compilar regex não é grátis.
    cached_corrector: RwLock<Option<std::sync::Arc<DictionaryCorrector>>>,
    persister: DiskPersister,
    save_version: AtomicU64,
}

impl DictionaryStore {
    /// Carrega do disco ou semeia com o padrão na primeira execução.
    pub fn load(path: PathBuf) -> Self {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let persister = DiskPersister::new(path.clone());

        let entries: Vec<DictionaryEntry> = std::fs::read(&path)
            .ok()
            .and_then(|data| serde_json::from_slice(&data).ok())
            .unwrap_or_else(default_entries);

        let store = Self {
            entries: RwLock::new(entries),
            cached_corrector: RwLock::new(None),
            persister,
            save_version: AtomicU64::new(0),
        };
        // Primeira execução: materializa o seed no disco.
        if !path.exists() {
            store.save();
        }
        store
    }

    pub fn entries(&self) -> Vec<DictionaryEntry> {
        self.entries.read().unwrap().clone()
    }

    pub fn corrector(&self) -> std::sync::Arc<DictionaryCorrector> {
        if let Some(cached) = self.cached_corrector.read().unwrap().as_ref() {
            return cached.clone();
        }
        let built = std::sync::Arc::new(DictionaryCorrector::new(&self.entries.read().unwrap()));
        *self.cached_corrector.write().unwrap() = Some(built.clone());
        built
    }

    pub fn bias_phrases(&self) -> Vec<String> {
        DictionaryCorrector::bias_phrases(&self.entries.read().unwrap())
    }

    pub fn add(&self, entry: DictionaryEntry) {
        self.entries.write().unwrap().insert(0, entry);
        self.mutated();
    }

    pub fn update(&self, entry: DictionaryEntry) {
        let mut entries = self.entries.write().unwrap();
        if let Some(index) = entries.iter().position(|e| e.id == entry.id) {
            entries[index] = entry;
            drop(entries);
            self.mutated();
        }
    }

    pub fn remove(&self, id: Uuid) {
        self.entries.write().unwrap().retain(|e| e.id != id);
        self.mutated();
    }

    pub fn toggle(&self, id: Uuid) {
        let mut entries = self.entries.write().unwrap();
        if let Some(entry) = entries.iter_mut().find(|e| e.id == id) {
            entry.is_enabled = !entry.is_enabled;
            drop(entries);
            self.mutated();
        }
    }

    /// Re-semeia qualquer entrada padrão ausente (par write+hear), sem duplicar nem
    /// sobrescrever edições do usuário.
    pub fn restore_defaults(&self) {
        let mut entries = self.entries.write().unwrap();
        let existing: std::collections::HashSet<String> = entries
            .iter()
            .map(|e| format!("{}→{}", e.hear.to_lowercase(), e.write.to_lowercase()))
            .collect();
        let missing: Vec<DictionaryEntry> = default_entries()
            .into_iter()
            .filter(|e| {
                !existing.contains(&format!(
                    "{}→{}",
                    e.hear.to_lowercase(),
                    e.write.to_lowercase()
                ))
            })
            .collect();
        if missing.is_empty() {
            return;
        }
        entries.extend(missing);
        drop(entries);
        self.mutated();
    }

    fn mutated(&self) {
        *self.cached_corrector.write().unwrap() = None;
        self.save();
    }

    fn save(&self) {
        let version = self.save_version.fetch_add(1, Ordering::SeqCst) + 1;
        let snapshot = self.entries.read().unwrap().clone();
        self.persister.save(snapshot, version);
    }
}

/// O dicionário que o Eko Nami traz de fábrica: vocabulário tech que engines de fala
/// sistematicamente erram, em inglês e português. A ordem importa: o viés é limitado a
/// `BIAS_LIMIT` e pega as *primeiras* entradas.
///
/// `(forma correta, [mis-hearings])`. Lista vazia = termo só de viés.
const DEFAULTS: &[(&str, &[&str])] = &[
    // AI tools & models — o vocabulário para o qual este app existe.
    (
        "Claude Code",
        &[
            "cloud code",
            "clawed code",
            "clode code",
            "claude codi",
            "cloud codi",
        ],
    ),
    ("Claude", &["clode", "cloude", "claud", "claudi"]),
    (
        "ChatGPT",
        &["chat gpt", "chat jipiti", "chatgipiti", "chat g p t"],
    ),
    ("GPT", &["jipiti"]),
    ("OpenAI", &["open a i", "openei"]),
    ("Anthropic", &["antropic", "antrópico", "an tropic"]),
    ("Codex", &["codeks", "code x", "kodex", "códex"]),
    ("Gemini", &["jemini", "jeminai", "gemeni"]),
    ("Copilot", &["co pilot", "copiloto"]),
    ("Cursor", &["kursor", "cursour"]),
    ("Windsurf", &["wind surf", "uindisurf"]),
    ("DeepSeek", &["deep seek", "deep sick", "dip siki"]),
    ("Ollama", &["olama", "o lhama"]),
    ("Llama", &["lhama"]),
    ("Mistral", &["mistrau"]),
    ("Grok", &["grock", "grook"]),
    ("Perplexity", &["perplexiti"]),
    ("Midjourney", &["mid journey", "midjorney"]),
    (
        "Hugging Face",
        &["haguin feice", "hagen face", "hug and face"],
    ),
    ("LangChain", &["lang chain", "langchein"]),
    ("Whisper", &["wisper", "uisper", "uispa"]),
    ("Parakeet", &["para keet", "paraquiti", "paraquite"]),
    ("LLM", &["l l m", "ele ele eme", "elelemi"]),
    ("MCP", &["m c p", "eme ce pe", "emcepe"]),
    ("RAG", &["ragui"]),
    ("fine-tuning", &["fine tunning", "fain tchuning"]),
    ("embedding", &["embedin", "embeding"]),
    ("vibe coding", &["vaib coding", "vibi coding"]),
    // Dev tools & platforms.
    (
        "GitHub",
        &[
            "git hub",
            "guitirrabe",
            "guite rabe",
            "guiti hab",
            "get hub",
        ],
    ),
    ("GitLab", &["git lab", "guitilab", "get lab"]),
    ("VS Code", &["v s code", "vê esse code", "viesse code"]),
    ("Xcode", &["x code", "xis code", "ex code"]),
    (
        "TypeScript",
        &["type script", "taipiscript", "taipe script"],
    ),
    ("JavaScript", &["java script", "java escript"]),
    ("Python", &["paiton", "páiton", "pyton"]),
    (
        "Next.js",
        &["next js", "nexjs", "next dot js", "nexti jota esse"],
    ),
    ("Node.js", &["node js", "node dot js", "nodejs"]),
    ("Tailwind", &["tail wind", "tailuind", "teiluindi"]),
    ("Supabase", &["supa base", "supabeis", "super base"]),
    ("Vercel", &["versel", "vercell", "ver sell", "verssel"]),
    ("PostgreSQL", &["postgres", "post gres", "postgree"]),
    ("Kubernetes", &["cubernetes", "kubernets", "cubernetis"]),
    ("kubectl", &["cube control", "cube cuddle"]),
    ("Docker", &["doquer", "docar"]),
    ("MySQL", &["my sql", "mai sequel"]),
    ("MongoDB", &["mongo db", "mongo de be"]),
    ("Redis", &["reddis"]),
    ("SQL", &["siquel", "esse que ele"]),
    ("GraphQL", &["graph cool", "graph q l", "graf quiuel"]),
    ("Firebase", &["fire base", "firebeis"]),
    ("Netlify", &["net life", "net lify"]),
    ("Cloudflare", &["cloud flare", "cloud fair", "cloudflair"]),
    ("AWS", &["a w s", "auessi"]),
    ("npm", &["n p m", "ene pe eme"]),
    ("pnpm", &["p n p m", "pinpim"]),
    ("shadcn", &["shad cn", "chadecene"]),
    ("tRPC", &["t r p c", "te erre pe ce"]),
    ("Prisma", &["prizma"]),
    ("Zod", &["zode", "zodd"]),
    ("Vite", &["viti"]),
    ("Playwright", &["play right", "play write", "plaiuraite"]),
    ("ESLint", &["es lint", "e s lint"]),
    ("Prettier", &["pretier", "pretty er"]),
    ("monorepo", &["mono repo", "mono repositório"]),
    ("package.json", &["package json", "package dot json"]),
    (".env", &["dot env", "ponto env"]),
    ("README", &["ridimi"]),
    ("JSON", &["jason", "jeison", "jotasom"]),
    ("YAML", &["iamel", "yamel", "ya mel"]),
    ("Markdown", &["markdaun"]),
    ("regex", &["reg ex", "regeks", "héguex"]),
    ("OAuth", &["o auth"]),
    ("JWT", &["j w t", "jota dabliu te"]),
    ("webhook", &["web hook", "uebi ruque"]),
    ("WebSocket", &["web socket", "uebsoquet"]),
    ("endpoint", &["end point", "endipoint"]),
    ("localhost", &["local host", "locau rosto"]),
    ("API", &["a p i", "eipiai"]),
    ("CLI", &["c l i", "ce ele i"]),
    ("GUI", &["gooey", "g u i", "guei"]),
    ("SDK", &["s d k", "esse de ka"]),
    ("CI/CD", &["ci cd", "c i c d"]),
    ("nginx", &["engine x", "enginex"]),
    ("Terraform", &["terra form"]),
    ("zsh", &["z s h", "zesh"]),
    ("C#", &["c sharp", "ce xarpe"]),
    ("C++", &["c plus plus", "ce mais mais", "c mais mais"]),
    (".NET", &["dot net", "ponto net"]),
    ("Django", &["diango", "jango"]),
    ("FastAPI", &["fast api", "fast a p i"]),
    ("SwiftUI", &["swift ui", "suift u i"]),
    ("Flutter", &["flater", "fluter"]),
    ("HTML", &["agá te eme ele", "h t m l"]),
    ("CSS", &["c s s", "ce esse esse"]),
    // Verbos & jargão dev (nos dois idiomas).
    ("deploy", &["deploi", "deplói"]),
    ("commit", &["comit", "comite"]),
    (
        "pull request",
        &["pul request", "pulha requeste", "pull requesty"],
    ),
    ("merge", &["merdge", "mergi"]),
    ("rebase", &["ribeis"]),
    ("branch", &["brench"]),
    ("backend", &["back end", "beque end", "beckend"]),
    ("frontend", &["front end", "fronti end"]),
    ("debug", &["dibag", "debugue"]),
    ("framework", &["freimuorc", "frame work"]),
    ("cache", &["caxe", "cachê"]),
    ("pipeline", &["pipe line"]),
    ("open source", &["open sors"]),
    ("useState", &["iusesteit"]),
    ("console.log", &["console log", "cônsoli log"]),
    // OS & tech de consumo.
    ("macOS", &["mac os", "mac o s", "mec o esse"]),
    ("iOS", &["i o s", "aiós"]),
    ("iPhone", &["i phone", "aifone", "ai fone"]),
    ("iPad", &["aipédi"]),
    ("Linux", &["linucs", "lainux"]),
    ("Wi-Fi", &["wifi", "uaifai", "wi fi"]),
    ("WhatsApp", &["whats app", "uatizapi", "watsap", "whatsap"]),
    ("Instagram", &["insta gram", "instagran"]),
    ("TikTok", &["tik tok", "tique toque"]),
    ("YouTube", &["you tube", "iutubi", "iutub"]),
    ("Google", &["gugou", "guguel"]),
    ("e-mail", &["imeiu", "imeio"]),
    ("LinkedIn", &["linked in", "linquidin"]),
    ("Slack", &["eslaque"]),
    ("Notion", &["nótion"]),
    ("Figma", &["figima"]),
    ("Raycast", &["ray cast", "rei cast"]),
    ("Stripe", &["istraipi", "straipe"]),
    ("WordPress", &["word press", "uordipress"]),
    ("n8n", &["n eight n", "ene oito ene"]),
    ("Zapier", &["zapiê"]),
    ("Obsidian", &[]),
    ("Eko Nami", &["eco nami", "eko nami"]),
];

pub fn default_entries() -> Vec<DictionaryEntry> {
    DEFAULTS
        .iter()
        .flat_map(|(write, hears)| {
            if hears.is_empty() {
                vec![DictionaryEntry::term(write)]
            } else {
                hears
                    .iter()
                    .map(|hear| DictionaryEntry::correction(hear, write))
                    .collect()
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_seed_is_substantial() {
        let entries = default_entries();
        assert!(
            entries.len() > 250,
            "seed should carry every mis-hearing variant"
        );
        assert!(entries
            .iter()
            .any(|e| e.write == "Claude Code" && e.hear == "cloud code"));
        assert!(entries
            .iter()
            .any(|e| e.kind == EntryKind::Term && e.write == "Obsidian"));
    }

    #[test]
    fn corrector_works_on_the_seed() {
        let corrector = DictionaryCorrector::new(&default_entries());
        let (text, _) = corrector.apply("abre o cloud code e commita no git hub");
        assert_eq!(text, "abre o Claude Code e commita no GitHub");
    }
}
