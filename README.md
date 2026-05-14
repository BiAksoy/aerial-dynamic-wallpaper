# Tahoe Dynamic Wallpaper

A small toolchain that turns macOS Tahoe's four separate aerial wallpapers
(Morning / Day / Evening / Night) into a single **solar-dynamic HEIC**
that macOS rotates natively based on the current sun position at your
location.

No cron job, no LaunchAgent, no background process. The system reads the
embedded `apple_desktop:solar` metadata and picks the right frame on its
own — and because the sun position is computed from Location Services,
the timing follows you when you travel.

## Requirements

- macOS Tahoe (or newer) with Apple's "Tahoe" aerial wallpapers available
  in System Settings → Wallpaper.
- Xcode Command Line Tools (provides `swift`). Install with:
  ```sh
  xcode-select --install
  ```
  This is a ~1 GB download if you don't already have it.
- Location Services enabled for "Setting Time Zone" / "System Customization"
  (recommended, for travel-aware rotation):
  System Settings → Privacy & Security → Location Services → System Services.
  Without it, macOS falls back to the time zone's representative location.

## How it works

1. `tahoe-extract-frames.swift` finds the four aerial `.mov` files that
   macOS has cached under
   `~/Library/Application Support/com.apple.wallpaper/aerials/videos/`,
   resolving the asset UUIDs by name from the live aerial manifest, and
   writes a poster PNG for each into `~/Pictures/AerialWallpapers/`.

2. `tahoe-build-dynamic.swift` packs the four PNGs into a single HEIC at
   `~/Pictures/AerialWallpapers/<Pack>-Dynamic.heic`. It attaches an
   `apple_desktop:solar` metadata block — a base64-encoded plist mapping
   each frame to representative sun (altitude, azimuth) anchors and
   light/dark appearance fallbacks.

3. `tahoe-install` chains the two and then sets the HEIC as the desktop
   wallpaper via AppleScript. macOS handles the rotation from there.

The default pack is **Tahoe** (the only Apple aerial pack that currently
ships all four Morning/Day/Evening/Night phases). All scripts accept
`--pack <Name>` so future packs that follow the same naming convention
will work without code changes.

## Install

```sh
# 1. Download all four Tahoe variants in the GUI.
#    Open System Settings → Wallpaper → Landscape.
#    Click the cloud-arrow icon on each of "Tahoe Morning", "Tahoe Day",
#    "Tahoe Evening", "Tahoe Night" until all four show the play icon
#    (= cached locally). The build will refuse with a clear error if any
#    of the four .mov files is missing.

# 2. Run the installer.
~/development/tahoe-dynamic-wallpaper/bin/tahoe-install
```

That's it. The installer prints what it's doing and which file it produced.
On success, your wallpaper is now the dynamic HEIC and macOS will rotate
through the four frames as the sun moves.

### First-run permission prompt

The first time `tahoe-install` runs, macOS will ask the terminal for
permission to control "System Events" (this is how the wallpaper actually
gets set). Approve it. If you dismiss the prompt by accident, the
wallpaper won't change — re-grant access in:

> System Settings → Privacy & Security → Automation → \[your terminal] → System Events

The script also works across multiple displays (it sets the wallpaper on
every desktop, not just the primary one).

### Verifying the build

To confirm the generated HEIC carries the right metadata:

```sh
~/development/tahoe-dynamic-wallpaper/bin/tahoe-inspect \
    ~/Pictures/AerialWallpapers/Tahoe-Dynamic.heic
```

It prints the frame count and dimensions, the light/dark appearance
mapping, and the full solar (altitude, azimuth → frame) table.

### Other aerial packs

```sh
~/development/tahoe-dynamic-wallpaper/bin/tahoe-install --pack Sequoia
```

The `--pack` flag works with any Apple aerial pack whose assets are
labelled `<Pack> Morning`, `<Pack> Day`, `<Pack> Evening`, `<Pack> Night`.
As of macOS Tahoe, only the **Tahoe** pack ships all four phases — the
flag is forward-looking for future macOS releases.

## Re-running

Re-run `tahoe-install` whenever you:

- (Re)download a Tahoe variant
- Edit the solar anchors in `bin/tahoe-build-dynamic.swift` (e.g. to push
  evening earlier or extend morning)

The build always overwrites the same HEIC path, so macOS picks up the new
frames immediately.

## Tuning the rotation

The sun-position table lives at the top of `bin/tahoe-build-dynamic.swift`:

```swift
let solar: [[String: Any]] = [
    ["a":   4.0, "z":  90.0, "i": 0],  // sunrise  → morning
    ["a":  25.0, "z": 130.0, "i": 0],  // mid-AM   → morning
    ["a":  60.0, "z": 180.0, "i": 1],  // noon     → day
    ["a":  25.0, "z": 230.0, "i": 1],  // mid-PM   → day
    ["a":   4.0, "z": 270.0, "i": 2],  // sunset   → evening
    ["a":  -8.0, "z": 300.0, "i": 2],  // dusk     → evening
    ["a": -40.0, "z":   0.0, "i": 3],  // midnight → night
    ["a":  -8.0, "z":  60.0, "i": 3],  // pre-dawn → night
]
```

Each row is `(altitude°, azimuth°, image_index)`. macOS picks the row
whose `(a, z)` is closest to the sun's current position. To bias a phase
earlier or later, lower its altitude; to shift its compass direction,
adjust azimuth (0° = north, 90° = east, 180° = south, 270° = west).

Defaults are tuned for mid-northern latitudes (≈30–45° N). Southern
hemisphere or polar travel still rotates correctly — transitions just
won't line up as precisely.

## Uninstall

```sh
# Restore an Apple wallpaper from System Settings → Wallpaper.
# Then delete the generated files:
rm -rf ~/Pictures/AerialWallpapers
rm -rf ~/development/tahoe-dynamic-wallpaper
```

## Files

```
tahoe-dynamic-wallpaper/
├── README.md
└── bin/
    ├── tahoe-extract-frames.swift   # aerial .mov → poster PNG
    ├── tahoe-build-dynamic.swift    # 4 PNGs → solar HEIC
    ├── tahoe-inspect                # decode + print HEIC metadata
    └── tahoe-install                # extract → build → set wallpaper
```

## Reference

- Apple's solar HEIC format is the same one used by the original Mojave
  "Dynamic Desktop" wallpapers. Third-party generators like
  [`wallpapper`](https://github.com/mczachurski/wallpapper) and
  [`Equinox`](https://github.com/rlxone/Equinox) document the format in
  more detail; this project bakes a minimal version of it directly.
- The Tahoe aerial UUIDs and human names are read from
  `~/Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json`.
