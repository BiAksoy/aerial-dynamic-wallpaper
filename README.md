# Aerial Dynamic Wallpaper

![Tahoe aerial wallpapers — morning, day, evening, night](docs/hero.jpg)

A small toolchain for macOS Tahoe (26) and Golden Gate (27) that turns
Apple's separate aerial wallpapers of one place at different times of
day, or any four images you provide, into a single **solar-dynamic HEIC**
that macOS rotates natively based on the current sun position at your
location.

No cron job, no LaunchAgent, no background process. The system reads the
embedded `apple_desktop:solar` metadata and picks the right frame on its
own — and because the sun position is computed from Location Services,
the timing follows you when you travel.

Three Apple packs are defined out of the box: **Golden Gate** (Day,
Sunset, Evening, Night; macOS 27), **Tahoe** (Morning, Day, Evening,
Night) and **Sequoia** (Sunrise, Morning, Night). Packs live in
`scenes.json`, and `aerial-build-dynamic` accepts arbitrary images via
`--images` for fully custom wallpapers.

## Requirements

- macOS Tahoe (or newer) with Apple's aerial wallpapers available
  in System Settings → Wallpaper. The videos do not need to be
  downloaded.
- Xcode Command Line Tools (provides `swift`). Install with:
  ```sh
  xcode-select --install
  ```
  This is a ~1 GB download if you don't already have it.
- Location Services enabled for "Setting Time Zone" / "System Customization"
  (recommended, for travel-aware rotation):
  System Settings → Privacy & Security → Location Services → System Services.
  When macOS has no location it places the sun as seen from the equator
  at your time zone's meridian, so the frames still rotate, with sunrise
  and sunset near 06:00 and 18:00 all year (see
  `docs/solar-selection.md`).

## How it works

1. `aerial-extract-frames` looks up the pack's clips in the live
   aerial manifest by the shot IDs listed in `scenes.json` and writes a
   poster PNG for each into `~/Pictures/AerialWallpapers/`. A clip that
   macOS has already cached under
   `~/Library/Application Support/com.apple.wallpaper/aerials/videos/`
   is read from there. Otherwise the single frame is read from the
   clip's URL in the manifest (Apple's `sylvan.apple.com`), which
   fetches a few megabytes instead of the 450-600 MB video.

2. `aerial-build-dynamic` packs the PNGs into a single HEIC at
   `~/Pictures/AerialWallpapers/<Pack>-Dynamic.heic`. It attaches an
   `apple_desktop:solar` metadata block — a base64-encoded plist mapping
   each frame to sun (altitude, azimuth) anchors and light/dark
   appearance fallbacks. The anchors are generated from the pack's
   schedule in `scenes.json`.

3. `aerial-install` chains the two and then sets the HEIC as the desktop
   wallpaper with `aerial-set-wallpaper`. macOS handles the rotation from
   there. It removes the poster PNGs once the HEIC is built;
   pass `--keep-frames` to keep them.

## Install

```sh
git clone https://github.com/BiAksoy/aerial-dynamic-wallpaper.git
cd aerial-dynamic-wallpaper
bin/aerial-install
```

That's it. The installer prints what it's doing and which file it produced.
On success, your wallpaper is now the dynamic HEIC and macOS will rotate
through the frames as the sun moves. To build the file without changing
your wallpaper, add `--no-set`.

Every command prints its options with `--help`.

Without `--pack`, the installer picks the newest pack in `scenes.json`
that your Mac's aerial manifest contains: Golden Gate on macOS 27, Tahoe
on macOS 26.

The wallpaper is set on every connected display, for the Space that is
showing on each. Other Spaces keep theirs unless "Show on all Spaces" is
on in System Settings → Wallpaper.

### Verifying the build

To confirm the generated HEIC carries the right metadata:

```sh
bin/aerial-inspect ~/Pictures/AerialWallpapers/GoldenGate-Dynamic.heic
```

It prints the frame count and dimensions, the light/dark appearance
mapping, and the full solar (altitude, azimuth → frame) table.

To see when each frame will be on screen, give it a place (latitude,
longitude in degrees) and optionally a date:

```sh
bin/aerial-inspect ~/Pictures/AerialWallpapers/GoldenGate-Dynamic.heic \
    --timeline 41.01,28.98 --date 2026-12-21
```

```
timeline: 2026-12-21 at 41.01, 28.98  (times in Europe/Istanbul)
        00:00  frame 1   (sun -68.2°)
        08:13  frame 0   (sun  -2.9°)
        16:27  frame 2   (sun  10.0°)
        17:40  frame 3   (sun  -1.0°)
        18:28  frame 1   (sun  -9.1°)
```

This works on any solar HEIC, including ones made with other tools, so
it is also a way to find out why a dynamic wallpaper switches when it
does. Times are within a few minutes; the simulation ignores atmospheric
refraction.

### Other aerial packs

```sh
bin/aerial-list                      # packs in scenes.json and their status
bin/aerial-install --pack Tahoe
bin/aerial-install --pack Sequoia
bin/aerial-install --pack "Golden Gate"
```

`--pack` takes any pack name from `scenes.json`. A pack is a list of
frames, each tied to an Apple aerial by its `shotID` in the manifest, and
a schedule (see [Tuning the rotation](#tuning-the-rotation)). To add one,
copy an entry and change the shot IDs; `bin/aerial-list --all` prints
every aerial on your Mac with its shot ID. A pack does not have to stay
within one place, and it can have any number of frames.

Sequoia has three clips and no evening one, so its Morning frame stays up
until sunset.

### Bring your own images

`aerial-build-dynamic` also works as a standalone HEIC builder for any
four images you supply — they don't have to come from an Apple aerial
pack:

```sh
bin/aerial-build-dynamic \
    --images morning.png day.png evening.png night.png \
    --out my-wallpaper.heic
```

Then set it as your wallpaper through System Settings or:

```sh
bin/aerial-set-wallpaper my-wallpaper.heic
```

For best results use four photos of the same scene at sunrise, midday,
sunset, and night. Same dimensions across all four.

## Re-running

Re-run `aerial-install` whenever you:

- Edit a schedule in `scenes.json` (e.g. to push evening earlier or
  extend morning)

## Tuning the rotation

Each pack in `scenes.json` has two schedules, written in the order the
frames appear, with the sun altitude (in degrees above the horizon) at
which one frame hands over to the next:

```json
{
  "name": "Golden Gate",
  "clips": {
    "day": "GG_A_DAY",
    "sunset": "GG_A_SUNSET",
    "evening": "GG_A_EVENING",
    "night": "GG_A_NIGHT"
  },
  "rising": ["night", -3, "day"],
  "setting": ["day", 10, "sunset", -1, "evening", -9, "night"],
  "light": "day",
  "dark": "night"
}
```

`rising` covers the first half of the solar day, while the sun climbs:
here Night stays until the sun is 3° below the horizon, then Day takes
over. `setting` covers the second half: Day until the sun has dropped to
10°, Sunset until it is 1° below the horizon, Evening until 9° below,
then Night. `light` and `dark` name the frames stored as the light and
dark appearance variants.

Useful reference altitudes: 0° is the horizon (sunrise and sunset), -6°
is the end of civil twilight (streetlights on), -12° is nautical
twilight (properly dark). To move a switch, change its number and re-run
`aerial-install`.

Because the schedule is written in sun altitudes, it does not depend on
latitude or hemisphere: a switch at 10° happens whenever the sun is at
10° where you are. `docs/solar-selection.md` records how macOS picks a
frame and how that was measured; the measurements were made with the sun
above the horizon, so the twilight switches rest on the same rule
without having been observed.

The `--images` mode uses a fixed four-frame schedule defined near the top
of `bin/aerial-build-dynamic`.

### Fixed clock times

```sh
bin/aerial-install --mode time
```

With `--mode time` the HEIC carries a clock table (`apple_desktop:h24`)
instead of a solar one, and macOS switches frames at fixed local times,
still without a background process. The times come from the pack's
`clock` schedule in `scenes.json`:

```json
"clock": ["night", "06:00", "day", "17:00", "sunset", "19:00", "evening", "21:00", "night"]
```

It reads like the solar schedules: frames in order, with the time each
one hands over to the next. The list starts and ends with the frame that
is shown across midnight. `--mode time` also works with `--images`
(06:00 morning, 11:00 day, 17:00 evening, 21:00 night).

The clock mode comes from
[rainhuang0220's fork](https://github.com/rainhuang0220/aerial-dynamic-wallpaper).

## Live video mode (macOS 27, experimental)

`aerial-install` produces a still wallpaper. On macOS 27 a pack can also
stay a live aerial, with the slow-motion video on the lock screen, and
still follow the sun: the aerial extension contains a solar scheduler
that no shipped aerial is configured to use.

```sh
bin/aerial-live enable        # or: enable --pack Tahoe
# Then, in System Settings → Wallpaper, choose the pack (now a single
# entry) and pick Automatic from its menu. If Automatic is already
# shown, pick another variant first and then Automatic again.
bin/aerial-live status        # schedule, and the clip on screen now
bin/aerial-live disable       # removes everything enable wrote
```

`enable` writes a copy of the aerial manifest in which the pack's clips
are grouped and carry solar anchors generated from the same `rising` and
`setting` schedules the still wallpaper uses, then points the aerial
extension at that copy. Things to know before using it:

- It depends on two undocumented settings of the aerial extension
  (`AerialManifestLocalPathOverride`, `AerialManifestForceLocal`) and can
  stop working with any macOS update. Checked on macOS 27.0.1.
- While it is on, macOS does not refresh its list of aerials.
- The pack's videos must be downloaded (System Settings → Wallpaper,
  cloud-arrow icon), and the pack must be exactly one Settings group, so
  packs mixed from different places only work as stills.
- It will not touch a manifest override that was set up by hand.
- A clip that is needed at more than one point of the day appears more
  than once in the pack's variant menu. The extra entries are hard links,
  not second downloads.

The scheduler and the two settings were worked out by
[pdfux](https://gist.github.com/pdfux/5659724021e584313c00b843312e909d).

## Uninstall

```sh
# If live mode is on:  bin/aerial-live disable
# Restore an Apple wallpaper from System Settings → Wallpaper.
# Then delete the generated files and the clone:
rm -rf ~/Pictures/AerialWallpapers
```

## Files

```
aerial-dynamic-wallpaper/
├── README.md
├── scenes.json                       # packs: frames, shot IDs, schedules
├── tests/run                         # checks that need no aerial videos
├── docs/
│   └── solar-selection.md            # how macOS picks a frame (measured)
└── bin/
    ├── aerial-list                   # packs, and every aerial's shot ID
    ├── aerial-extract-frames         # aerial clip → poster PNG
    ├── aerial-build-dynamic          # PNGs → dynamic HEIC
    ├── aerial-inspect                # decode + print HEIC metadata
    ├── aerial-set-wallpaper          # set an image on every display
    ├── aerial-install                # extract → build → set wallpaper
    └── aerial-live                   # sun-driven live aerial (macOS 27)
```

`aerial-extract-frames` and `aerial-build-dynamic` used to end in
`.swift`; the old names remain as links.

## Tests

```sh
tests/run
```

This checks everything that does not need Apple's videos: the generated
solar and clock tables, the timeline simulation, every pack in
`scenes.json`, rejected schedules and argument handling. It works in a
temporary directory and never sets the wallpaper. What macOS does with
the files cannot be tested this way; `docs/solar-selection.md` records
how that was measured.

## Reference

- Apple's solar HEIC format is the same one used by the original Mojave
  "Dynamic Desktop" wallpapers. Third-party generators like
  [`wallpapper`](https://github.com/mczachurski/wallpapper) and
  [`Equinox`](https://github.com/rlxone/Equinox) document the format in
  more detail; this project bakes a minimal version of it directly.
- Aerial asset UUIDs and shot IDs are read from
  `~/Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json`.
- The Sequoia mapping and the clock mode follow
  [rainhuang0220's fork](https://github.com/rainhuang0220/aerial-dynamic-wallpaper).
