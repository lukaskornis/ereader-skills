//! Claude chat relay for the router: the e-reader posts a question, this asks the Claude API and returns
//! the reply as an HTML fragment, whole (POST /chat) or as it is written (POST /chat/stream).
//! Same protocol as relay.py on the Mac; see router.md.

mod provider;

use base64::Engine;
use regex_lite::Regex;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, SystemTime};

const WINDOW: u64 = 1_000_000;
const MAX_BODY: usize = 1 << 20;
const SESSIONS_MAX_BYTES: u64 = 10 << 20;
// The reader gives up after 60 s of silence; thinking can be quiet for longer.
const KEEPALIVE: Duration = Duration::from_secs(20);
const IMG_TIMEOUT: Duration = Duration::from_secs(8);
// No resizing on the router, so big images are dropped rather than shrunk.
const IMG_MAX_BYTES: u64 = 1_500_000;
const IMG_THUMB_PX: u32 = 960;
const WRONG_KEY: &str = "Wrong relay key. Run: deploy.sh pair";
const NO_KEY: &str = "No Claude credential on the router. Put the subscription token in /etc/claudechat/oauth_token";

macro_rules! prompt_base {
    () => {
        r#"You are a thoughtful companion whose replies are read on a black-and-white e-ink reader, like pages of a well-edited book.
Write flowing, warm, precise prose: real paragraphs, a clear line of thought, concrete images and examples.
Output an HTML fragment only, using just these tags: p, em, strong, h3, ul, ol, li, blockquote, table, tr, th, td, img, svg and SVG shapes.
Use a table when comparing several things along the same dimensions. Use an inline svg diagram (a landscape viewBox about 400 units wide, no width or height attributes, black and grey strokes and fills, text font-size at least 14 in viewBox units, no scripts) when a picture explains it better than words: a mechanism, a shape, a timeline, a graph.
Use img only for a real photo or painting at a URL you are certain exists, preferably on upload.wikimedia.org; add alt text. Never invent URLs.
No markdown, no code blocks unless explicitly asked, no emoji, no preamble like "Great question".
Do not end with offers or questions such as "Would you like..."; the reader has buttons for that.
"#
    };
}
const SYSTEM_PROMPT: &str = concat!(prompt_base!(), "Aim for about 250 to 600 words unless the request calls for less.");
/// Long Send on the reader asks for this instead.
const LONG_SYSTEM_PROMPT: &str = concat!(prompt_base!(), "Write an in-depth article of about 2,000 to 5,000 words, organised under h3 headings: go well past a summary into background, how it works, examples, nuances and open questions.");

fn dir() -> PathBuf {
    PathBuf::from(std::env::var("CLAUDECHAT_DIR").unwrap_or_else(|_| "/etc/claudechat".into()))
}

fn sessions_dir() -> PathBuf {
    dir().join("sessions")
}

fn random_bytes(n: usize) -> Vec<u8> {
    let mut buf = vec![0u8; n];
    fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut buf))
        .expect("/dev/urandom");
    buf
}

fn write_private(path: &PathBuf, contents: &str) -> std::io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    let mut f = fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(path)?;
    f.write_all(contents.as_bytes())
}

fn relay_key() -> String {
    let path = dir().join("key");
    if let Ok(key) = fs::read_to_string(&path) {
        if !key.trim().is_empty() {
            return key.trim().to_string();
        }
    }
    let key = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(random_bytes(24));
    write_private(&path, &key).expect("write relay key");
    key
}

/// The subscription token (`claude setup-token`, sk-ant-oat…) wins over an API key. Read on every
/// request, so pasting it needs no restart.
fn api_key() -> Option<String> {
    let key = std::env::var("CLAUDE_CODE_OAUTH_TOKEN")
        .ok()
        .or_else(|| fs::read_to_string(dir().join("oauth_token")).ok())
        .or_else(|| std::env::var("ANTHROPIC_API_KEY").ok())
        .or_else(|| fs::read_to_string(dir().join("api_key")).ok())?;
    let key = key.trim().to_string();
    (!key.is_empty()).then_some(key)
}

fn same(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

struct Request {
    method: String,
    path: String,
    headers: HashMap<String, String>,
    body: Vec<u8>,
}

fn read_request(stream: &TcpStream) -> Option<Request> {
    let mut reader = BufReader::new(stream.take(MAX_BODY as u64 + 64 * 1024));
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    let mut parts = line.split_whitespace();
    let method = parts.next()?.to_string();
    let path = parts.next()?.to_string();
    let mut headers = HashMap::new();
    loop {
        line.clear();
        if reader.read_line(&mut line).ok()? == 0 {
            return None;
        }
        let trimmed = line.trim_end();
        if trimmed.is_empty() {
            break;
        }
        if let Some((name, value)) = trimmed.split_once(':') {
            headers.insert(name.trim().to_ascii_lowercase(), value.trim().to_string());
        }
    }
    let length: usize = headers.get("content-length").and_then(|v| v.parse().ok()).unwrap_or(0);
    if length > MAX_BODY {
        return None;
    }
    let mut body = vec![0u8; length];
    reader.read_exact(&mut body).ok()?;
    Some(Request { method, path, headers, body })
}

fn reply(mut stream: &TcpStream, code: u16, obj: &Value) {
    let status = match code {
        200 => "OK",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        _ => "Bad Gateway",
    };
    let body = obj.to_string();
    let head = format!(
        "HTTP/1.0 {} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        code,
        status,
        body.len()
    );
    let _ = stream.write_all(head.as_bytes()).and_then(|_| stream.write_all(body.as_bytes()));
}

fn handle(stream: TcpStream, key: &str) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(30)));
    let Some(req) = read_request(&stream) else { return };
    let authorized = same(req.headers.get("x-key").map(String::as_str).unwrap_or(""), key);
    let route = (req.method.as_str(), req.path.as_str());
    match route {
        ("GET", "/ping") | ("POST", "/chat") | ("POST", "/chat/stream") => {}
        _ => return reply(&stream, 404, &json!({"error": "not found"})),
    }
    if !authorized {
        return reply(&stream, 403, &json!({"error": WRONG_KEY}));
    }
    if route.0 == "GET" {
        return reply(&stream, 200, &json!({"ok": true, "token": api_key().is_some()}));
    }
    let Ok(body) = serde_json::from_slice::<Value>(&req.body) else {
        return reply(&stream, 400, &json!({"error": "bad request"}));
    };
    let Some(ask) = Ask::from(&body) else {
        return reply(&stream, 400, &json!({"error": "empty prompt"}));
    };
    if route.1 == "/chat" {
        let result = chat(&ask, &mut |_| true);
        let code = if result.get("error").is_some() { 502 } else { 200 };
        return reply(&stream, code, &result);
    }
    stream_chat(stream, ask);
}

/// One JSON object per line, flushed as Claude writes; the connection closes after the last one.
fn stream_chat(mut stream: TcpStream, ask: Ask) {
    let head = "HTTP/1.0 200 OK\r\nContent-Type: application/x-ndjson\r\nConnection: close\r\n\r\n";
    if stream.write_all(head.as_bytes()).is_err() {
        return;
    }
    let (tx, rx) = mpsc::channel::<Value>();
    let gone = Arc::new(AtomicBool::new(false));
    let worker_gone = gone.clone();
    std::thread::spawn(move || {
        let delta_tx = tx.clone();
        let result = chat(&ask, &mut |piece| {
            if !piece.is_empty() && delta_tx.send(json!({ "delta": piece })).is_err() {
                return false;
            }
            !worker_gone.load(Ordering::Relaxed)
        });
        let _ = tx.send(result);
    });
    loop {
        let (obj, last) = match rx.recv_timeout(KEEPALIVE) {
            Ok(obj) => {
                let last = obj.get("delta").is_none();
                (obj, last)
            }
            Err(RecvTimeoutError::Timeout) => (json!({"delta": ""}), false),
            Err(RecvTimeoutError::Disconnected) => return,
        };
        let line = obj.to_string() + "\n";
        if stream.write_all(line.as_bytes()).and_then(|_| stream.flush()).is_err() {
            gone.store(true, Ordering::Relaxed);
            eprintln!("reader hung up, Claude stopped");
            return;
        }
        if last {
            return;
        }
    }
}

struct Ask {
    prompt: String,
    session_id: Option<String>,
    opening: String,
    model: String,
    effort: Option<String>,
    long: bool,
}

impl Ask {
    fn from(body: &Value) -> Option<Ask> {
        let text = |k: &str| body[k].as_str().unwrap_or("").trim().to_string();
        let prompt = text("prompt");
        if prompt.is_empty() {
            return None;
        }
        let model = text("model");
        let effort = text("effort");
        let session_id = text("session_id");
        Some(Ask {
            prompt,
            session_id: (!session_id.is_empty()).then_some(session_id),
            opening: text("opening"),
            model: if ["sonnet", "opus", "haiku"].contains(&model.as_str()) { model } else { "sonnet".into() },
            effort: ["low", "medium", "high", "max"].contains(&effort.as_str()).then_some(effort),
            long: text("length") == "long",
        })
    }
}

fn valid_session_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

fn load_history(id: &str) -> Option<Vec<Value>> {
    let text = fs::read_to_string(sessions_dir().join(format!("{id}.json"))).ok()?;
    serde_json::from_str::<Value>(&text).ok()?["messages"].as_array().cloned()
}

fn save_history(id: &str, messages: &[Value]) {
    let dir = sessions_dir();
    let _ = fs::create_dir_all(&dir);
    let part = dir.join(format!("{id}.json.part"));
    let text = json!({ "messages": messages }).to_string();
    if write_private(&part, &text).and_then(|_| fs::rename(&part, dir.join(format!("{id}.json")))).is_err() {
        eprintln!("could not save session {id}");
        return;
    }
    prune_sessions();
}

fn prune_sessions() {
    let Ok(entries) = fs::read_dir(sessions_dir()) else { return };
    let mut files: Vec<(SystemTime, u64, PathBuf)> = entries
        .filter_map(|e| {
            let e = e.ok()?;
            let meta = e.metadata().ok()?;
            Some((meta.modified().ok()?, meta.len(), e.path()))
        })
        .collect();
    let mut total: u64 = files.iter().map(|f| f.1).sum();
    files.sort();
    for (_, len, path) in files {
        if total <= SESSIONS_MAX_BYTES {
            break;
        }
        if fs::remove_file(&path).is_ok() {
            total -= len;
        }
    }
}

/// The finished reply ({session_id, html, usage}) or {error}. History is saved only after a reply, so a
/// failed request leaves no dangling question behind.
fn chat(ask: &Ask, on_text: &mut dyn FnMut(&str) -> bool) -> Value {
    let Some(api_key) = api_key() else { return json!({"error": NO_KEY}) };
    let known = ask.session_id.as_deref().filter(|id| valid_session_id(id));
    let history = known.and_then(load_history);
    let id = match known {
        Some(id) => id.to_string(),
        None => random_bytes(16).iter().map(|b| format!("{b:02x}")).collect(),
    };
    // The opening prompt leads the first question of a new chat; resumed chats already hold it.
    let mut messages = history.clone().unwrap_or_default();
    let prompt = if history.is_none() && !ask.opening.is_empty() {
        format!("{}\n\n{}", ask.opening, ask.prompt)
    } else {
        ask.prompt.clone()
    };
    messages.push(json!({"role": "user", "content": prompt}));
    let system = if ask.long { LONG_SYSTEM_PROMPT } else { SYSTEM_PROMPT };
    let reply = match provider::stream(&api_key, &ask.model, ask.effort.as_deref(), system, &messages, on_text) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("claude: {e}");
            return json!({ "error": e });
        }
    };
    messages.push(json!({"role": "assistant", "content": reply.blocks}));
    save_history(&id, &messages);
    json!({
        "session_id": id,
        "html": inline_images(&strip_fence(&reply.text)),
        "usage": {"context": reply.context_tokens, "window": WINDOW},
    })
}

fn regex(cell: &'static OnceLock<Regex>, pattern: &str) -> &'static Regex {
    cell.get_or_init(|| Regex::new(pattern).expect("valid regex"))
}

fn strip_fence(html: &str) -> String {
    static FENCE: OnceLock<Regex> = OnceLock::new();
    regex(&FENCE, r"^\s*```(?:html)?\s*|\s*```\s*$").replace_all(html, "").into_owned()
}

/// Wikimedia only serves some thumbnail widths and originals can be huge: try the URL, then a 960 px
/// thumbnail, then the original.
fn image_candidates(url: &str) -> Vec<String> {
    static THUMB: OnceLock<Regex> = OnceLock::new();
    static ORIGINAL: OnceLock<Regex> = OnceLock::new();
    let thumb = regex(&THUMB, r"^(https://upload\.wikimedia\.org/wikipedia/[^/]+)/thumb(/[0-9a-f]/[0-9a-f]{2}/([^/]+))/[^/]+$");
    let original = regex(&ORIGINAL, r"^(https://upload\.wikimedia\.org/wikipedia/[^/]+)(/[0-9a-f]/[0-9a-f]{2}/([^/]+))$");
    let mut out = vec![url.to_string()];
    let caps = thumb.captures(url).or_else(|| original.captures(url));
    if let Some(c) = caps {
        let name = &c[3];
        let suffix = if name.to_ascii_lowercase().ends_with(".svg") { ".png" } else { "" };
        out.push(format!("{}/thumb{}/{}px-{}{}", &c[1], &c[2], IMG_THUMB_PX, name, suffix));
        out.push(format!("{}{}", &c[1], &c[2]));
    }
    out.dedup();
    out
}

fn download(url: &str) -> Option<(String, Vec<u8>)> {
    let response = ureq::get(url)
        .timeout(IMG_TIMEOUT)
        .set("User-Agent", "claudechat-relay/1.0 (e-reader chat)")
        .call()
        .ok()?;
    let mime = response.content_type().to_ascii_lowercase();
    if !mime.starts_with("image/") {
        return None;
    }
    let mut body = Vec::new();
    response.into_reader().take(IMG_MAX_BYTES + 1).read_to_end(&mut body).ok()?;
    (body.len() as u64 <= IMG_MAX_BYTES).then_some((mime, body))
}

/// The image at url as a data: URI the reader can show offline, or None.
fn fetch_image(url: &str) -> Option<String> {
    let (mime, body) = image_candidates(url).iter().find_map(|u| download(u))?;
    Some(format!("data:{};base64,{}", mime, base64::engine::general_purpose::STANDARD.encode(body)))
}

/// The reader is offline from the web: images are fetched here and embedded; ones that fail are dropped.
fn inline_images(html: &str) -> String {
    static IMG: OnceLock<Regex> = OnceLock::new();
    let img = regex(&IMG, r#"(?i)<img\b[^>]*?\bsrc=["'](https?://[^"']+)["'][^>]*>"#);
    let mut urls: Vec<String> = Vec::new();
    for c in img.captures_iter(html) {
        if !urls.contains(&c[1].to_string()) {
            urls.push(c[1].to_string());
        }
    }
    if urls.is_empty() {
        return html.to_string();
    }
    let mut found: HashMap<String, Option<String>> = HashMap::new();
    for batch in urls.chunks(4) {
        std::thread::scope(|s| {
            let handles: Vec<_> = batch.iter().map(|u| s.spawn(move || fetch_image(u))).collect();
            for (u, h) in batch.iter().zip(handles) {
                found.insert(u.clone(), h.join().ok().flatten());
            }
        });
    }
    img.replace_all(html, |c: &regex_lite::Captures| match &found[&c[1]] {
        Some(uri) => c[0].replace(&c[1], uri),
        None => String::new(),
    })
    .into_owned()
}

fn main() {
    let port = std::env::var("CLAUDECHAT_PORT").unwrap_or_else(|_| "8787".into());
    fs::create_dir_all(dir()).expect("config dir");
    let key: &'static str = Box::leak(relay_key().into_boxed_str());
    // The reader runs the relay for itself and binds to 127.0.0.1 only.
    let bind = std::env::var("CLAUDECHAT_BIND").unwrap_or_else(|_| "0.0.0.0".into());
    let listener = TcpListener::bind(format!("{bind}:{port}")).expect("bind");
    eprintln!("claudechat relay on {bind}:{port}");
    for stream in listener.incoming().flatten() {
        let spawned = std::thread::Builder::new()
            .stack_size(512 * 1024)
            .spawn(move || handle(stream, key));
        if let Err(e) = spawned {
            eprintln!("thread: {e}");
        }
    }
}
