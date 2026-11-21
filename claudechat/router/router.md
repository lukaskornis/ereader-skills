# Router relay (OpenWrt, verified 2026-11-21 against a mock API and the real API's auth)

A Rust replacement for `relay.py` that runs on the router (ASUS RT-AX57 Go, OpenWrt, aarch64) and calls the Claude API directly, on the Claude subscription (OAuth token) or an API key. Same protocol as the Mac relay, so the plugin is unchanged; only its host and key differ.

## Protocol
- `GET /ping` (header `X-Key`) → `{"ok":true,"token":<API key present>}`; wrong key 403, other paths 404.
- `POST /chat/stream {prompt, session_id, model, effort, opening, length}` → NDJSON: `{delta}` pieces, then `{session_id, html, usage:{context, window}}` or `{error}`. No `five_hour` (API keys have no 5-hour limit; the reader hides it). An empty `{"delta":""}` goes out every 20 s of silence, since the reader gives up after 60 s and thinking can be quiet longer.
- `length: "long"` (Long Send) uses the long-form system prompt; both prompts share one base text, only the length line differs.
- `POST /chat` → the whole reply in one object, 502 on error.

## How it works
- `src/provider.rs` is the only code that knows the provider: one `stream()` taking messages, model and effort, returning content blocks, text and context tokens. Another provider would be another `stream()`.
- Auth: `/etc/claudechat/oauth_token` (from `claude setup-token`, `sk-ant-oat…`, valid about a year, no refresh code) wins over `api_key`. A subscription token goes as `Authorization: Bearer` with `anthropic-beta: oauth-2025-04-20` and the system prompt led by "You are Claude Code, Anthropic's official CLI for Claude.", or the API rejects it. Verified 2026-11-21 with a real Haiku reply. Anthropic's terms bar subscription tokens in third-party tools (Feb 2026); Lukas accepted that risk.
- Raw HTTP to `/v1/messages` (ureq + rustls, webpki roots), `anthropic-version: 2026-10-21`, `max_tokens` 64000, top-level `cache_control` for automatic caching, `output_config.effort` only when given. No `thinking` field (adaptive by default) and no sampling parameters (both 400 on this version). Models: sonnet/opus/haiku → `claude-*-5-5`.
- The API is stateless, so history lives in `/etc/claudechat/sessions/<id>.json`. Assistant turns are stored as the exact content blocks, thinking and signature included, because edited thinking makes the next request fail. History is written only after a reply succeeds; the oldest files go once the folder passes 10 MB. An unknown session id (an old Mac chat) starts fresh under that id, with the opening prompt.
- Images: every `<img src="http…">` is fetched (8 s, 4 at a time), Wikimedia URLs fall back to a 960 px thumbnail and then the original, and the image is inlined as `data:`. No resizing on the router, so anything over 1.5 MB is dropped, like a failed fetch.
- A reader that hangs up stops the upstream request at the next event. 600 s limit.
- Thread per connection, own small HTTP parser. About 1 MB RSS idle, 1.5 MB peak in a request; binary 1.5 MB.

## Files on the router
- `/usr/bin/claudechat`, procd service `/etc/init.d/claudechat` (respawn, logs in `logread -e claudechat`).
- `/etc/claudechat/key` relay key (made on first run), `/etc/claudechat/api_key` the Anthropic API key (read on each request, no restart needed), `sessions/`. The folder is in `/etc/sysupgrade.conf`.
- Env overrides for testing: `CLAUDECHAT_DIR`, `CLAUDECHAT_PORT`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY`.

## Use
- `./deploy.sh` builds with `cargo zigbuild` for `aarch64-unknown-linux-musl` (needs `brew install zig`, `cargo install cargo-zigbuild`, `rustup target add aarch64-unknown-linux-musl`), copies over ssh with `cat` (dropbear has no sftp) and starts the service.
- Subscription token from the Mac keychain: `security find-generic-password -s claudechat-token -w | tr -d '\n' | ssh root@192.168.50.1 'umask 077; cat > /etc/claudechat/oauth_token'`. Or put an API key in: `ssh root@192.168.50.1 'umask 077; cat > /etc/claudechat/api_key'`, paste, Ctrl-D.
- `./deploy.sh pair [device]` points a reader (or all in ink's `devices.json`) at `192.168.50.1:8787`. `relay.py pair` points it back at the Mac.

## Pitfalls
- zsh aborts a whole command line on an unmatched glob (`rm log*` with no match), so test scripts list files by name.
