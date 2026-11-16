#!/bin/bash
# Downloads KOReader and the Kindle jailbreak tools into this folder and checks
# them against SHA256SUMS (the exact files verified on the KT2 and Aura ONE).
# A hash mismatch means a newer release than the tested one: it warns, keeps the file.
# --src also unpacks the KOReader source for local reading into ../koreader-src.
set -u
cd "$(dirname "$0")"
KO=v2026.07.1
KM=https://kindlemodding.org/jailbreaking/Legacy

get() {  # url [name]
    local name="${2:-$(basename "$1")}"
    [ -s "$name" ] && return 0
    echo "fetch $name"
    curl -fsSL --retry 2 -o "$name.part" "$1" && mv "$name.part" "$name" || { rm -f "$name.part"; echo "FAILED $name"; }
}

get "https://github.com/koreader/koreader/releases/download/$KO/koreader-kindlepw2-$KO.zip"
get "https://github.com/koreader/koreader/releases/download/$KO/koreader-kobo-$KO.zip"
get "$KM/KindleBreak/jb-kindlebreak.zip"
get "$KM/KindleBreak/file__0.localstorage"
get "https://github.com/KindleModding/Hotfix/releases/latest/download/Update_hotfix_universal.bin"
get "https://github.com/KindleTweaks/PEKI/releases/latest/download/PEKI.zip"
get "$KM/post-jailbreak/installing-kual-mrpi/kual-mrinstaller-khf.zip"
get "$KM/post-jailbreak/renameotabin.zip"

while read -r sum name; do
    [ -f "$name" ] || continue
    [ "$(shasum -a 256 "$name" | cut -d' ' -f1)" = "$sum" ] && echo "ok   $name" || echo "NEWER $name (not the tested build)"
done < SHA256SUMS

if [ "${1:-}" = "--src" ]; then
    mkdir -p "../koreader-src/$KO"
    curl -fL "https://github.com/koreader/koreader/archive/refs/tags/$KO.tar.gz" | tar xz -C "../koreader-src/$KO"
    mv "../koreader-src/$KO/koreader-${KO#v}" "../koreader-src/$KO/koreader" 2>/dev/null
fi
