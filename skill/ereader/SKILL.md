---
name: ereader
description: Make a Kindle or Kobo fast and modern on KOReader, then develop and test on it over Wi-Fi with the `ink` CLI (screenshot, tap, swipe, push, log, restart, get/set settings, shell). Use for jailbreaking a Kindle, installing or speeding up KOReader, Kobo setup, KOReader plugins or custom UI, or anything that drives the e-reader remotely.
---

# E-reader (Kindle + Kobo, KOReader)

The pack is the repo this skill is linked from (`install.sh` links `skill/ereader` into `~/.claude/skills/`). Read its `_index.md` first, then load only the docs the task needs.

- `ink` is on the PATH. Devices are in `~/.config/ink/devices.json`; pick one with `ink -d kobo …`.
- Items in `kobo.md` and `kindle.md` are UNVERIFIED until tested on the device. Mark each one with the date once it works.
- Every feature must work on both readers or hide itself where the hardware lacks it (no front light, no light sensor, no CPU governor). Check `Device:has…()` or the sysfs file, never the model name.
- Firmware rules, never-do lists and the dev loop are in `_index.md` and the docs. Follow them exactly.
