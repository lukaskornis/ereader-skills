# Word search

KOReader plugin: English word search puzzles. Tools menu > Word search.

## Use
- Home: Continue (thumbnail of the saved board, theme, size, progress), New puzzle in four sizes, two switches.
- Sizes: Small 8×8 with 6 words, Medium 11×11 with 10, Big 14×14 with 15, Huge 18×18 with 22.
- Switches: Diagonal words (new boards place words on all eight lines, else the four straight ones, backwards included) and Show words left (pill and progress bar in the header).
- Swipe across a word. A live outline follows the finger on the nearest allowed line; on release the stroke snaps to the unfound word whose ends best match it, either way round, forgiving max(1.6, 0.3 × length) cells in total end error.
- A find flashes the word black, shows a cheer in the header, then leaves a grey marker; the word is struck out in the list. All found: confetti, SOLVED tiles, time, stars (under 20 s a word 3, under 40 s 2).
- Menu goes back home. Closing (✕ on home, or KOReader exit through FlushSettings) saves the board.

## Files
- `logic.lua`: rules with no KOReader dependency: seeded board generation, snapping, preview line. Mac check: `luajit wordsearch/logic_test.lua` (invariants over 2400 boards, determinism, snapping).
- `words.lua`: 12 themes of 35 words; each must fill a Huge board (22 words of 12 letters or fewer).
- `main.lua`: one full-screen widget painting itself with Blitbuffer; tap targets are collected while painting.

## State
- `wordsearch_game` in `G_reader_settings`: plain table (size, n, theme, letters, words with ends and found flags, elapsed seconds, done, seed). Saved after every find with a flush, on Menu and on close.
- `wordsearch_diagonals`, `wordsearch_show_left`: switches, default on.

## Refresh
- Stroke outline: DU ("fast") on the box of the old and new line only; cleaned with "ui" on release.
- Find: "ui"; win panel and mode changes: "flashui".

## Dev
- Push and reload: `ink -d kobo reload wordsearch wordsearch/wordsearch.koplugin`. The first install needs `ink restart` to load the plugin.
- `ink tap` takes full-resolution coordinates: multiply screenshot pixels by the printed scale.

Verified on the Kobo Aura One, 2026-11-18: home screen, new board, strokes snapping and the found marker.
