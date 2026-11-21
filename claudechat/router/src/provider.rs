//! The one place that talks to a model provider. Swapping in another provider means another `stream`.

use serde_json::{json, Value};
use std::io::{BufRead, BufReader};
use std::time::{Duration, Instant};

pub const TIMEOUT: Duration = Duration::from_secs(600);
pub const TOO_SLOW: &str = "Claude took longer than 10 minutes.";
const CLAUDE_CODE_PREFIX: &str = "You are Claude Code, Anthropic's official CLI for Claude.";
pub const HUNG_UP: &str = "reader hung up";

pub struct Reply {
    /// Every content block exactly as the API sent it, thinking and signatures included; the next turn
    /// must send them back unchanged.
    pub blocks: Vec<Value>,
    pub text: String,
    pub context_tokens: u64,
}

pub fn model_id(model: &str) -> &'static str {
    match model {
        "opus" => "claude-opus-5-5",
        "haiku" => "claude-haiku-5-5",
        _ => "claude-sonnet-5-5",
    }
}

fn base_url() -> String {
    std::env::var("ANTHROPIC_BASE_URL").unwrap_or_else(|_| "https://api.anthropic.com".into())
}

fn error_message(body: &str) -> String {
    let parsed: Option<Value> = serde_json::from_str(body).ok();
    let message = parsed
        .as_ref()
        .and_then(|v| v["error"]["message"].as_str())
        .unwrap_or(body);
    message.chars().take(400).collect()
}

/// Streams one reply. `on_text` gets each piece of text as it is written; returning false stops the
/// request (the reader hung up).
pub fn stream(
    api_key: &str,
    model: &str,
    effort: Option<&str>,
    system: &str,
    messages: &[Value],
    on_text: &mut dyn FnMut(&str) -> bool,
) -> Result<Reply, String> {
    let subscription = api_key.starts_with("sk-ant-oat");
    // Subscription tokens are only accepted when the system prompt opens as Claude Code.
    let system = if subscription {
        json!([{"type": "text", "text": CLAUDE_CODE_PREFIX}, {"type": "text", "text": system}])
    } else {
        json!(system)
    };
    let mut body = json!({
        "model": model_id(model),
        "max_tokens": 64000,
        "stream": true,
        "system": system,
        "messages": messages,
        "cache_control": {"type": "ephemeral"},
    });
    if let Some(effort) = effort {
        body["output_config"] = json!({ "effort": effort });
    }
    let started = Instant::now();
    let mut request = ureq::post(&format!("{}/v1/messages", base_url()))
        .timeout(TIMEOUT)
        .set("anthropic-version", "2026-10-21")
        .set("content-type", "application/json");
    request = if subscription {
        request
            .set("authorization", &format!("Bearer {api_key}"))
            .set("anthropic-beta", "oauth-2025-04-20")
    } else {
        request.set("x-api-key", api_key)
    };
    let response = request.send_string(&body.to_string());
    let response = match response {
        Ok(r) => r,
        Err(ureq::Error::Status(code, r)) => {
            let text = r.into_string().unwrap_or_default();
            return Err(format!("Claude API {}: {}", code, error_message(&text)));
        }
        Err(e) if started.elapsed() >= TIMEOUT => return Err(format!("{} ({})", TOO_SLOW, e)),
        Err(e) => return Err(format!("Could not reach Claude: {}", e)),
    };

    let mut blocks: Vec<Value> = Vec::new();
    let mut text = String::new();
    let mut usage = json!({});
    let mut stop_reason = String::new();
    let mut finished = false;
    for line in BufReader::new(response.into_reader()).lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) if started.elapsed() >= TIMEOUT => return Err(TOO_SLOW.into()),
            Err(e) => return Err(format!("Connection to Claude dropped: {}", e)),
        };
        let Some(data) = line.strip_prefix("data:") else { continue };
        let Ok(event) = serde_json::from_str::<Value>(data.trim()) else { continue };
        match event["type"].as_str().unwrap_or("") {
            "message_start" => merge(&mut usage, &event["message"]["usage"]),
            "content_block_start" => {
                let index = event["index"].as_u64().unwrap_or(blocks.len() as u64) as usize;
                if blocks.len() <= index {
                    blocks.resize(index + 1, Value::Null);
                }
                blocks[index] = event["content_block"].clone();
            }
            "content_block_delta" => {
                let index = event["index"].as_u64().unwrap_or(0) as usize;
                let Some(block) = blocks.get_mut(index) else { continue };
                let delta = &event["delta"];
                match delta["type"].as_str().unwrap_or("") {
                    "text_delta" => {
                        let piece = delta["text"].as_str().unwrap_or("");
                        append(block, "text", piece);
                        text.push_str(piece);
                        if !on_text(piece) {
                            return Err(HUNG_UP.into());
                        }
                    }
                    "thinking_delta" => append(block, "thinking", delta["thinking"].as_str().unwrap_or("")),
                    "signature_delta" => block["signature"] = delta["signature"].clone(),
                    _ => {}
                }
            }
            "message_delta" => {
                merge(&mut usage, &event["usage"]);
                if let Some(reason) = event["delta"]["stop_reason"].as_str() {
                    stop_reason = reason.into();
                }
            }
            "message_stop" => {
                finished = true;
                break;
            }
            "error" => return Err(error_message(&event.to_string())),
            _ => {}
        }
        // Thinking writes no text for a long while; this lets the caller notice a reader that left.
        if !on_text("") {
            return Err(HUNG_UP.into());
        }
    }
    if !finished {
        return Err("Claude stopped before finishing.".into());
    }
    if stop_reason == "refusal" {
        return Err("Claude declined to answer this.".into());
    }
    let context_tokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
        .iter()
        .map(|k| usage[*k].as_u64().unwrap_or(0))
        .sum();
    blocks.retain(|b| !b.is_null());
    Ok(Reply { blocks, text, context_tokens })
}

fn append(block: &mut Value, field: &str, piece: &str) {
    match &mut block[field] {
        Value::String(s) => s.push_str(piece),
        slot => *slot = Value::String(piece.into()),
    }
}

fn merge(into: &mut Value, from: &Value) {
    let Some(from) = from.as_object() else { return };
    for (k, v) in from {
        if !v.is_null() {
            into[k] = v.clone();
        }
    }
}
