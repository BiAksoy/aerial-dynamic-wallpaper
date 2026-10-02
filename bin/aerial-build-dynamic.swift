#!/usr/bin/env swift
// Builds a dynamic HEIC. By default it is solar: macOS reads the embedded
// apple_desktop:solar metadata and picks the right image based on the
// current sun position (computed from Location Services), so the
// wallpaper rotates natively and adapts when you travel. With
// --mode time it embeds apple_desktop:h24 instead and macOS switches
// frames at fixed local clock times.
//
// Two sources:
//
//   aerial-build-dynamic [--pack <Name>] [--mode solar|time]
//       Reads the pack's frames from ~/Pictures/AerialWallpapers/
//       ("<pack>-<frame>.png", as written by aerial-extract-frames) and
//       writes "<Pack>-Dynamic.heic" alongside them. The pack's frames
//       and schedule come from ../scenes.json. Default: the first pack
//       in scenes.json whose frames are all on disk.
//
//   aerial-build-dynamic --images <morning> <day> <evening> <night> [--out <path>] [--mode solar|time]
//       Builds a HEIC from any four images. Output defaults to
//       ~/Pictures/AerialWallpapers/Custom-Dynamic.heic.

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8)); exit(code)
}

// --- Parse args.
var requestedPack: String? = nil
var customImages: [String] = []
var outOverride: String? = nil
var mode = "solar"
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    switch args.removeFirst() {
    case "--pack":
        guard !args.isEmpty else { fail("--pack requires a value", code: 2) }
        requestedPack = args.removeFirst()
    case "--images":
        guard args.count >= 4 else { fail("--images requires 4 paths (morning day evening night)", code: 2) }
        customImages = Array(args.prefix(4))
        args.removeFirst(4)
    case "--out":
        guard !args.isEmpty else { fail("--out requires a value", code: 2) }
        outOverride = args.removeFirst()
    case "--mode":
        guard !args.isEmpty else { fail("--mode requires solar or time", code: 2) }
        mode = args.removeFirst()
        guard mode == "solar" || mode == "time" else { fail("unknown --mode \(mode) (use solar or time)", code: 2) }
    case let other:
        fail("unknown argument: \(other)", code: 2)
    }
}

let dir = ("~/Pictures/AerialWallpapers" as NSString).expandingTildeInPath
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

// --- A scene is a set of named frames plus the schedules that say when
// each is shown. A schedule lists frames in the order they appear, with
// the point of each switch between them. For the sun that point is its
// altitude (degrees): "rising" covers solar midnight → noon, "setting"
// covers noon → midnight. For "clock" it is minutes after local midnight.
struct Schedule { let frames: [String]; let thresholds: [Double] }
struct Scene {
    let name: String
    let frames: [String: String]   // frame name → image path
    let rising: Schedule
    let setting: Schedule
    let clock: Schedule?
    let light: String
    let dark: String
}

// Each switch is pinned by two anchors this far (degrees) either side of it.
let anchorOffset = 0.5

func parseSchedule(_ raw: Any?, _ key: String, ascending: Bool) -> Schedule {
    guard let items = raw as? [Any], items.count % 2 == 1 else {
        fail("\(key) must alternate frame names and altitudes, starting and ending with a frame")
    }
    var frames: [String] = []
    var thresholds: [Double] = []
    for (i, item) in items.enumerated() {
        if i % 2 == 0, let frame = item as? String { frames.append(frame) }
        else if i % 2 == 1, !(item is String), let altitude = (item as? NSNumber)?.doubleValue { thresholds.append(altitude) }
        else { fail("\(key) must alternate frame names and altitudes, starting and ending with a frame") }
    }
    for (a, b) in zip(thresholds, thresholds.dropFirst()) where (ascending ? b - a : a - b) < 2 * anchorOffset + 0.5 {
        fail("\(key) altitudes must \(ascending ? "increase" : "decrease") by more than \(2 * anchorOffset + 0.5)° per step")
    }
    return Schedule(frames: frames, thresholds: thresholds)
}

func parseClock(_ raw: Any?, _ key: String) -> Schedule? {
    guard let raw else { return nil }
    guard let items = raw as? [String], items.count % 2 == 1, items.count >= 3 else {
        fail("\(key) must alternate frame names and HH:MM times, starting and ending with a frame")
    }
    var frames: [String] = []
    var minutes: [Double] = []
    for (i, item) in items.enumerated() {
        if i % 2 == 0 { frames.append(item); continue }
        let parts = item.split(separator: ":").map { Int($0) }
        guard parts.count == 2, let h = parts[0], let m = parts[1], (0...23).contains(h), (0...59).contains(m) else {
            fail("\(key): \(item) is not an HH:MM time")
        }
        minutes.append(Double(h * 60 + m))
    }
    guard zip(minutes, minutes.dropFirst()).allSatisfy({ $0 < $1 }) else { fail("\(key) times must increase") }
    guard frames.first == frames.last else { fail("\(key) must start and end with the frame shown across midnight") }
    return Schedule(frames: frames, thresholds: minutes)
}

let scene: Scene
let outFile: String
if !customImages.isEmpty {
    scene = Scene(
        name: "Custom",
        frames: Dictionary(uniqueKeysWithValues: zip(["morning", "day", "evening", "night"], customImages)),
        rising: Schedule(frames: ["night", "morning", "day"], thresholds: [-7, 10]),
        setting: Schedule(frames: ["day", "evening", "night"], thresholds: [3, -9]),
        clock: Schedule(frames: ["night", "morning", "day", "evening", "night"], thresholds: [360, 660, 1020, 1260]),
        light: "day", dark: "night")
    outFile = outOverride ?? "\(dir)/Custom-Dynamic.heic"
} else {
    let scenesURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scenes.json")
    guard let data = try? Data(contentsOf: scenesURL),
          let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        fail("cannot read pack definitions at \(scenesURL.path)")
    }
    func framePaths(_ entry: [String: Any]) -> [String: String] {
        let prefix = (entry["name"] as? String ?? "").lowercased().filter { !$0.isWhitespace }
        let names = (entry["clips"] as? [String: String] ?? [:]).keys
        return Dictionary(uniqueKeysWithValues: names.map { ($0, "\(dir)/\(prefix)-\($0).png") })
    }
    let entry: [String: Any]
    if let requestedPack {
        guard let match = json.first(where: { $0["name"] as? String == requestedPack }) else {
            let names = json.compactMap { $0["name"] as? String }.joined(separator: ", ")
            fail("unknown pack \"\(requestedPack)\". Packs in scenes.json: \(names)")
        }
        entry = match
    } else {
        guard let match = json.first(where: {
            framePaths($0).values.allSatisfy { FileManager.default.fileExists(atPath: $0) }
        }) else {
            fail("no extracted pack frames in \(dir). Run aerial-install, or pass --pack or --images")
        }
        entry = match
    }
    guard let name = entry["name"] as? String,
          let light = entry["light"] as? String, let dark = entry["dark"] as? String else {
        fail("scenes.json: every pack needs name, clips, rising, setting, light and dark")
    }
    scene = Scene(
        name: name,
        frames: framePaths(entry),
        rising: parseSchedule(entry["rising"], "\(name) rising", ascending: true),
        setting: parseSchedule(entry["setting"], "\(name) setting", ascending: false),
        clock: parseClock(entry["clock"], "\(name) clock"),
        light: light, dark: dark)
    outFile = outOverride ?? "\(dir)/\(name.filter { !$0.isWhitespace })-Dynamic.heic"
}

// --- Frame order in the HEIC: the light frame first, because image 0 is
// what thumbnails and non-dynamic viewers show; then by first appearance.
let scheduled: [String]
if mode == "time" {
    guard let clock = scene.clock else { fail("\(scene.name) has no clock schedule in scenes.json, so --mode time cannot build it") }
    scheduled = clock.frames
} else {
    scheduled = scene.rising.frames + scene.setting.frames
}
var order: [String] = []
for frame in [scene.light] + scheduled + [scene.dark] where !order.contains(frame) {
    order.append(frame)
}
let unknown = order.filter { scene.frames[$0] == nil }
if !unknown.isEmpty {
    fail("\(scene.name): schedule uses frames the pack does not define: \(unknown.joined(separator: ", "))")
}
let unused = scene.frames.keys.filter { !scheduled.contains($0) }.sorted()
if !unused.isEmpty {
    fail("\(scene.name): frames never shown by the schedule: \(unused.joined(separator: ", "))")
}
// The two schedules hand over to each other at solar noon and midnight.
// Keeping the frame the same across both handovers also means an anchor
// from the other side of the sky can never win with a different frame.
if mode == "solar", scene.rising.frames.last != scene.setting.frames.first || scene.setting.frames.last != scene.rising.frames.first {
    fail("\(scene.name): rising must end with the frame setting starts with, and setting must end with the frame rising starts with")
}

// --- Solar anchors: (altitude°, azimuth°, image index).
// macOS only compares altitudes among the anchors on the sun's side of
// the sky (measured on macOS 27.0.1, see docs/solar-selection.md), so
// the rising schedule goes on the east side and the setting schedule on
// the west, and the nearest altitude wins. Two anchors straddling each
// switch put it at exactly the scheduled altitude at any latitude.
func anchors(_ schedule: Schedule, azimuth: Double, ascending: Bool) -> [[String: Any]] {
    func anchor(_ altitude: Double, _ frame: String) -> [String: Any] {
        ["a": altitude, "z": azimuth, "i": order.firstIndex(of: frame)!]
    }
    if schedule.thresholds.isEmpty { return [anchor(0, schedule.frames[0])] }
    let step = ascending ? anchorOffset : -anchorOffset
    return schedule.thresholds.enumerated().flatMap { k, altitude in
        [anchor(altitude - step, schedule.frames[k]), anchor(altitude + step, schedule.frames[k + 1])]
    }
}
let solar = anchors(scene.rising, azimuth: 90, ascending: true)
    + anchors(scene.setting, azimuth: 270, ascending: false)

// --- Clock entries: (fraction of the day, image index). macOS shows the
// latest entry at or before the current time and does not look back past
// midnight (measured on macOS 27.0.1; first reported in rainhuang0220's
// fork), so the frame shown across midnight needs its own entry at 00:00.
var h24: [[String: Any]] = []
if mode == "time", let clock = scene.clock {
    h24.append(["t": 0.0, "i": order.firstIndex(of: clock.frames[0])!])
    for (k, minutes) in clock.thresholds.enumerated() {
        h24.append(["t": minutes / 1440, "i": order.firstIndex(of: clock.frames[k + 1])!])
    }
}

// --- Load the source images, error out cleanly if any are missing.
var images: [CGImage] = []
var missingFrames: [String] = []
for frame in order {
    let path = scene.frames[frame]!
    guard FileManager.default.fileExists(atPath: path) else {
        missingFrames.append(frame); continue
    }
    guard let isrc = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(isrc, 0, nil) else {
        fail("decode failed: \(path)")
    }
    images.append(img)
}
if !missingFrames.isEmpty {
    if !customImages.isEmpty {
        fail("missing image(s): \(missingFrames.map { scene.frames[$0]! }.joined(separator: ", "))")
    }
    fail("""
        missing source frames for: \(missingFrames.joined(separator: ", "))
        Extract them first:  aerial-extract-frames --pack "\(scene.name)"
        """)
}

// --- Light/Dark appearance fallback. If a user forces Light or Dark mode
// (overriding Auto), macOS uses these indices instead of the schedule.
let appearance: [String: Int] = [
    "l": order.firstIndex(of: scene.light)!,
    "d": order.firstIndex(of: scene.dark)!,
]

// --- Encode the metadata as a base64 binary plist (Apple's format).
// Only one of the two tags is written, so there is no question of which
// one macOS would prefer.
let tagName = mode == "time" ? "h24" : "solar"
let plistData = try PropertyListSerialization.data(
    fromPropertyList: mode == "time" ? ["ap": appearance, "ti": h24] : ["ap": appearance, "si": solar],
    format: .binary,
    options: 0)
let tagBase64 = plistData.base64EncodedString()

// --- Build the HEIC with the apple_desktop metadata on the primary image.
let outURL = URL(fileURLWithPath: outFile)
try? FileManager.default.removeItem(at: outURL)
guard let dest = CGImageDestinationCreateWithURL(
        outURL as CFURL, UTType.heic.identifier as CFString, images.count, nil) else {
    fail("cannot create HEIC at \(outFile)")
}

let metadata = CGImageMetadataCreateMutable()
CGImageMetadataRegisterNamespaceForPrefix(
    metadata,
    "http://ns.apple.com/namespace/1.0/" as CFString,
    "apple_desktop" as CFString, nil)
guard let tag = CGImageMetadataTagCreate(
        "http://ns.apple.com/namespace/1.0/" as CFString,
        "apple_desktop" as CFString,
        tagName as CFString,
        .string,
        tagBase64 as CFString) else {
    fail("metadata tag creation failed")
}
CGImageMetadataSetTagWithPath(metadata, nil, "apple_desktop:\(tagName)" as CFString, tag)

// No quality option on purpose. ImageIO's default (0.8) measured 48-54 dB
// against the 4K source frames with no banding in the night and sunset
// skies; 0.95 made the file four times larger for about 1 dB.
CGImageDestinationAddImageAndMetadata(dest, images[0], metadata, nil)
for img in images.dropFirst() {
    CGImageDestinationAddImage(dest, img, nil)
}
guard CGImageDestinationFinalize(dest) else {
    fail("HEIC finalize failed")
}

let bytes = (try? FileManager.default.attributesOfItem(atPath: outFile)[.size] as? Int) ?? 0
let mb = Double(bytes) / 1_048_576
print(String(format: "wrote %@ (%.1f MB, %d frames: %@, %@)",
             outFile, mb, images.count, order.joined(separator: " "),
             mode == "time" ? "\(h24.count) clock entries" : "\(solar.count) solar anchors"))
