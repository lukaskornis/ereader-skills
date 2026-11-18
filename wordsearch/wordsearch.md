# Word search

KOReader plugin: English word search puzzles. Tools menu > Word search.

## Use
- Home: tile logo (WORD crossed by a hand-drawn line), all-time count of unique words found, Continue (thumbnail, theme, size, one square per word), New puzzle as four plain size buttons, three switches.
- Sizes: Small 8×8 with 6 words, Medium 11×11 with 10, Big 14×14 with 15, Huge 18×18 with 22.
- Switches: Diagonal words (new boards place words on all eight lines, else the four straight ones, backwards included), Show progress (a row of hollow squares under the theme that fill as words are found), Hide word list (the list then shows only found words).
- Easy first: the shortest 40% of a board's words read left to right or top to bottom; the rest go backwards or (when on) diagonal, falling back to any direction only when a crowded board has no room.
- Decoys: 3 to 6 starts of listed words (3 to 5 letters, never the whole word) sit in free lines. No listed word ever reads twice: placements, decoys and filler that would spell a second copy are undone or re-rolled.
- Header: back chevron top left, theme, progress squares.
- Draw across a word: a pencil line follows the finger. On release the trail vanishes and the stroke snaps to the unfound word whose ends best match it, either way round, forgiving max(1.6, 0.3 × length) cells in total end error.
- A find gets a thin black line (radius 4% of a cell, letters stay readable) through its letters shaped like the drawn stroke: the stroke is fitted onto the word (`Logic.fitStroke`), its wobble scaled down only as far as needed to stay within 0.22 cells. In the list the word keeps its font and gets a hand-drawn strike, each a different wobble. All found: confetti, SOLVED tiles, time, stars (under 20 s a word 3, under 40 s 2).
- No greys anywhere (owner's call, 2026-11-18): every frame is thresholded to pure black and white, so A2 shows it exactly and nothing needs a flash.
- Menu goes back home. Closing (✕ on home, or KOReader exit through FlushSettings) saves the board.

## Files
- `logic.lua`: rules with no KOReader dependency: seeded board generation, snapping, preview line. Mac check: `luajit wordsearch/logic_test.lua` (invariants over 2400 boards, easy share, each word reads exactly once, determinism, snapping).
- `words.lua`: 12 themes of 35 words; each must fill a Huge board (22 words of 12 letters or fewer).
- `main.lua`: one full-screen widget painting itself with Blitbuffer; tap targets are collected while painting.

## State
- `wordsearch_game` in `G_reader_settings`: plain table (size, n, theme, letters, words with ends and found flags, elapsed seconds, done, seed). Saved after every find with a flush, on Menu and on close.
- `wordsearch_diagonals`, `wordsearch_show_left`: switches, default on. `wordsearch_hide_words`: default off.
- A found word stores `path`: flat t, d pairs (along, across the word, in cells), up to 24 points.
- `wordsearch_seen` (set of words) and `wordsearch_seen_count`: unique words found across all games.

## Refresh and latency
- The page is rendered into an off-screen BB8 frame, then only the part shown is thresholded (< 0xA0 black) and copied to the screen.
- Pencil: each pan segment is painted straight into `Screen.bb` (row-filled stroke, radius `PEN`) and its box refreshed with A2, one refresh per input batch (`nextTick`).
- Release: frame re-rendered (84 ms for Huge on the Aura One), then the trail plus word box, the word list and the header are copied and refreshed with DU (A2 left a grey ghost of a missed trail). A new touch or a tap first wipes any trail whose gesture never sent a release. No UIManager repaint, no flash. Mode changes, the win panel and the first show use "ui" (no flash).
- Markers are filled row by row (`capsule`). paintCircle is per pixel: one board took 3.8 s with chained circles.

## Dev
- Push and reload: `ink -d kobo reload wordsearch wordsearch/wordsearch.koplugin`. The first install needs `ink restart` to load the plugin.
- `ink tap` takes full-resolution coordinates: multiply screenshot pixels by the printed scale.

Verified on the Kobo Aura One, 2026-11-18: home screen, new board, strokes snapping and the found marker.
