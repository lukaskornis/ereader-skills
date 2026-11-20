# Minesweeper: manual checks

Expected result after the arrow.

1. Shelf > Apps > Mines → home: MINES tiles, difficulty pill, four size cards, No guessing switch.
2. Pick Hard, then Huge → empty hatched board; first tap opens an area, no mine.
3. Long press a hatched cell → black flag, mine count drops; long press again → flag gone.
4. Header toggle to flag, tap a cell → flags it; long press still flags.
5. Tap a number whose flags are all placed → its other neighbours open.
6. Bulb → a ring marks a safe cell; dig it → opens, ring gone.
7. Dig a mine → all mines show, wrong flags crossed, header shows Undo and New game; Undo → board back, game goes on.
8. Clear a board → confetti card, stars (3 minus undos and hints), time, "New best!" on a first win.
9. Menu, then home → best time under that size card, boards cleared and streak line.
10. Leave mid-game, reopen KOReader → Continue card resumes the same board.
11. Moves never flash the screen; nothing refreshes while idle.

## Audit
- No timers or polling: the only scheduled task is the settings flush 0.3 s after a move.
- Seeded generation, deterministic per seed and first dig (tested).
- Tests are about 8 % of the diff, pure logic only.
- Open: home screen has empty space at the bottom; the win card's header still shows the mine count.
- The device's Shelf was patched by hand (its apps row is newer than main's); main's Shelf change may conflict when the Word search and Paint branches merge.
