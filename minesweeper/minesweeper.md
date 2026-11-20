# Minesweeper

KOReader plugin: Minesweeper made for e-ink. Shelf > Apps > Mines, or Tools menu > Minesweeper.

## Use
- Home: MINES tiles (a mine for the I), boards cleared and current streak, Continue card (thumbnail, difficulty, size, mines left), difficulty pill (Easy 12 %, Normal 16 %, Hard 20 % mines), four board-shaped size cards with the best time for the chosen difficulty, a No guessing switch, how-to glyph rows.
- Sizes (portrait, the panel's 3:4): Small 8×10, Medium 11×14, Big 14×18, Huge 17×22.
- Tap digs, hold flags. The header toggle (shovel / flag) swaps them. Tapping an open number whose flags are all placed digs its other neighbours.
- The first dig is always an opening: no mine in the 3×3 around it.
- No guessing (default on): boards are re-rolled until a solver using only what the player sees (single counts, the subset rule, the mine total) clears them from the first dig.
- Hint (bulb in the header): marks a hidden cell that can be proven safe from the open numbers.
- A mine ends the game with every mine shown, wrong flags crossed, and the header turned into Undo and New game; the board stays readable. Undo takes back that dig.
- Win: confetti card, time, stars (3, minus one per undo or hint, at least 1), "New best!" on a record.

## Made for e-ink
- No live clock: an idle board never refreshes. Time counts only while the game is on screen.
- Hidden cells are solid black tiles, open cells white, so every dig reads as black turning white. Pure black and white, every frame thresholded, so DU shows it exactly and nothing flashes.
- Each move copies only the changed cells' box (plus the header) to the panel with DU. A mine or a win repaints the screen once.

## Files
- `logic.lua`: rules with no KOReader dependency: seeded mine placement, the no-guess solver, dig, chord, flag, undo, hint, stars. Mac check: `luajit minesweeper/logic_test.lua` (40 seeds per size and difficulty: mine count, first-dig opening, every board logical; three boards per kind solved by hints alone; determinism; chord, boom and undo).
- `main.lua`: one full-screen widget painting itself with Blitbuffer; tap targets are collected while painting.

## State
- `minesweeper_game` in `G_reader_settings`: plain table (size, diff, rows, cols, mines, seed, bomb set, state string `h`/`o`/`f` per cell, boom, done, undos, hints, hint, elapsed). Saved after every move, flushed 0.3 s later.
- `minesweeper_diff`, `minesweeper_logical`: home choices. `minesweeper_best` (`<size>_<diff>` → seconds), `minesweeper_wins`, `minesweeper_streak`.

## Generation cost (Mac, luajit)
Huge Hard about 29 ms a board with retries, Big Hard 10 ms. The Kobo is roughly 10 to 20 times slower.

## Dev
- First install: push the folder and `ink restart`. After that: `ink -d kobo reload minesweeper minesweeper/minesweeper.koplugin`.
