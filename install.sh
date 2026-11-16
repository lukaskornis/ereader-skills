#!/bin/bash
# Mac side setup: Python 3.14 from Homebrew, `ink` on the PATH, the Claude Code skill,
# one SSH key per reader. Safe to run again.
set -eu
REPO="$(cd "$(dirname "$0")" && pwd)"

command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh"; exit 1; }
# ink needs compression.zstd, new in Python 3.14.
brew list python@3.14 >/dev/null 2>&1 || brew install python@3.14
PY="$(brew --prefix python@3.14)/bin/python3.14"
"$PY" -c 'from compression import zstd' || { echo "Python 3.14 from Homebrew is broken: $PY"; exit 1; }

mkdir -p "$HOME/.local/bin" "$HOME/.claude/skills"
# A wrapper rather than a symlink, so ink always runs on this Python whatever python3 is first on the PATH.
rm -f "$HOME/.local/bin/ink"
printf '#!/bin/sh\nexec "%s" "%s/ink" "$@"\n' "$PY" "$REPO" > "$HOME/.local/bin/ink"
chmod 755 "$HOME/.local/bin/ink"
ln -sfn "$REPO/skill/ereader" "$HOME/.claude/skills/ereader"

for dev in kindle kobo; do
    key="$HOME/.ssh/${dev}_ed25519"
    [ -f "$key" ] || ssh-keygen -q -t ed25519 -f "$key" -N '' -C "ink-$dev"
done

case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "Add ~/.local/bin to your PATH: echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zprofile" ;; esac
echo "Done. Next: setup.md step 2."
