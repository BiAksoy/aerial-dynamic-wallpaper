# How macOS picks a frame from a solar HEIC

Apple does not document this. The rule below was measured on macOS 27.0.1
(26A434) on 2 October 2026 by setting solid-colour test HEICs as the
wallpaper with `NSWorkspace.setDesktopImageURL` and reading back which
frame was on screen. `bin/aerial-build-dynamic` relies on it.

## The rule

Every anchor in the `si` table is an (altitude, azimuth, frame) triple.
For the sun's current position macOS scores each anchor, and the lowest
score wins:

1. The sky is split into an east half (azimuth up to and including 180°)
   and a west half (above 180°).
2. An anchor in the same half as the sun scores its altitude difference
   from the sun. Its azimuth is ignored.
3. An anchor in the other half scores its full angular separation from
   the sun.
4. An anchor whose azimuth differs from the sun's by 180° or more (plain
   subtraction, no wrap-around) is skipped.

So "nearest anchor" is the wrong mental model: on the sun's side of the
sky only altitude counts.

## Evidence

Each row is one test HEIC. The sun was at about altitude 40°, azimuth
148° (east half).

| Anchors offered | Shown | What it rules out |
|---|---|---|
| at the sun; two far below the horizon on the other side | at the sun | selection by frame order or by the appearance block |
| same altitude but 100° away in azimuth (east); 21° lower at the sun's azimuth | same altitude | nearest by flat or great-circle distance |
| 32° higher at the sun's azimuth; same altitude 36° away in azimuth | same altitude | flat distance |
| same altitude in the west half; 21° lower in the east half | 21° lower, east | altitude alone, ignoring the half |
| where the sun was 100 minutes earlier; where it would be 30 minutes later | the later one | "last anchor the sun has passed" |
| two anchors, both in the west half | the one with the smaller separation | |
| 70° lower in the east half; same altitude at azimuth 190° (west) | west one | dropping the other half before scoring |
| same altitude at azimuth exactly 180°; 10° lower at the sun's azimuth | azimuth 180° | 180° counting as west |
| same altitude at azimuth 340°; 110° lower in the east half | east one | the 180° cut-off using wrapped differences |

The build script's own output was then tested the same way: probe packs
with a schedule switch placed 1.5° to 2° above or below the sun's
altitude showed the frame the schedule promised in every case, with the
sun in the east half (rising schedule) and later in the west half
(setting schedule).

`aerial-inspect --timeline` implements the rule. Its prediction for the
current minute matched the frame on screen for four hand-typed tables
(8 to 14 anchors at mixed azimuths), once with the sun in each half.

The rule matches what
[pdfux's notes](https://gist.github.com/pdfux/5659724021e584313c00b843312e909d)
describe for the scheduler of macOS 27's aerial video wallpapers.

## Other observations

- The frame changed on its own within a minute of the sun crossing a
  switch placed just ahead of it.
- Frame order in the file and the `ap` (light/dark) block had no effect
  on which frame was shown, with the system in Light appearance and
  appearance set to Auto.
- A wallpaper set with `NSWorkspace.setDesktopImageURL` behaved as a
  dynamic wallpaper straight away, on both attached displays.

## Which location macOS uses

Normally the sun altitude macOS used (read off a ladder of anchors 0.5°
apart) was within 0.2° of the value computed for the Mac's actual region.

For about an hour during the tests the same ladder showed the sun about
40° higher, matching the sun as seen from latitude 0° at the time zone's
standard meridian (longitude 15° × UTC offset). Location Services was on
throughout, but several system location clients had stopped receiving
location at the same time, so this looks like what macOS does when it
has no location at all. It first showed up after a `WallpaperAgent`
restart; repeating the restart later, on a system that had its location,
did not bring it back. A reboot restored the real location.

Under that fallback the sun rises near 06:00 and sets near 18:00 standard
time all year and passes almost overhead, so a schedule still produces a
plausible day, only not the local one.

## How the build script uses it

A pack's `rising` schedule becomes anchors at azimuth 90° and its
`setting` schedule anchors at azimuth 270°, so while the sun climbs only
the rising anchors are compared by altitude, and while it sinks only the
setting ones. Each switch gets two anchors, 0.5° either side of the
scheduled altitude, one per neighbouring frame. The switch then happens
at that altitude regardless of latitude, season or hemisphere.

## Clock tables

A HEIC built with `--mode time` carries `apple_desktop:h24` instead: a
`ti` list of (fraction of the day, frame) entries. Measured the same way
on the same build:

- macOS shows the entry with the latest time at or before now. The order
  of the entries in the file does not matter.
- It does not look back past midnight. With no entry at or before the
  current time, it showed the first frame, not the previous day's last
  entry. A table therefore needs an entry at 00:00.
- A switch two minutes ahead happened on its own within five seconds of
  the scheduled minute.

## Aerial videos

`bin/aerial-live` uses the aerial extension's own scheduler, which reads
one `variant.solar` anchor per manifest entry. Measured on the same
build with the four Golden Gate clips:

- With anchors that made one clip the clear winner, that clip played,
  and after swapping the anchors the other clip played. Which clip had
  the lowest `preferredOrder` made no difference.
- A switch placed a few minutes ahead happened on its own, about a
  minute from the predicted time, also when the target was a copied
  entry whose video is a hard link.
- The scheduler used the same sun position as the still wallpapers did
  at that moment (the fallback described above).
- The grouped entry shows Automatic in System Settings before any choice
  is stored. Until one is, the stored choice stays `default` and a single
  clip plays. Picking another variant and then Automatic stores provider
  `com.apple.wallpaper.choice.aerials` with the group's id and the option
  `aerialVariant = automatic`, and from then on the anchors decide.

## Not tested

- The sun below the horizon.
- Dark appearance, and the Light and Dark choices in System Settings.
- macOS 26.
