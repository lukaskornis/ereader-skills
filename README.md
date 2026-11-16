# ereader-skills

Make an old e-reader fast and pleasant on [KOReader](https://github.com/koreader/koreader), and let an AI agent (or you) work on it over Wi-Fi.

<p>
<img src="screenshots/shelf.png" width="49%" alt="Shelf home screen">
<img src="screenshots/reader.png" width="49%" alt="Reading a book">
</p>

## Why
Stock e-reader software is slow and closed. KOReader is open but plain and fiddly to tune. This gives you:

- **Shelf**: a home screen with covers, your current book and reading time left. Covers are fetched online when a book has none.
- **Speed patches**: full CPU while reading, faster page turns, the reader menu ready before you tap.
- **Send**: get a book onto the reader from your phone or Mac with a 4-letter code, or send it from one reader to another.
- **ink**: a command line tool to screenshot, tap, push books, change settings and hot-reload code on the reader from your Mac, with no cables.
- **Agent skills**: docs written for an AI agent. Point Claude Code (or any agent that reads files) at them and ask for changes; it edits, reloads and checks the screenshot itself.

## Who it's for
People with a Kindle or Kobo (or any reader KOReader runs on) who want it faster and nicer, and tinkerers who want to build their own reader UI with an agent's help.

Tested daily on a Kindle Basic 7th gen and a Kobo Aura ONE. Other readers should work: every feature checks the hardware and hides what is missing.

## Install
On a Mac with [Homebrew](https://brew.sh):
```bash
git clone https://github.com/lukaskornis/ereader-skills && cd ereader-skills
./install.sh
```
Then follow [setup.md](setup.md): KOReader on the reader, SSH on, then
```bash
ink -d kobo find      # or -d kindle
ink -d kobo install   # Shelf and speed patches
```

## Use it with an agent
- Claude Code: `install.sh` adds the `ereader` skill. Ask "make the Shelf header bigger on my Kobo".
- Any other agent: tell it to read `_index.md` first.

## License
MIT. KOReader and the third-party tools fetched by `downloads/fetch.sh` keep their own licenses.
