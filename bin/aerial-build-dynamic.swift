#!/usr/bin/env swift
// Builds a solar-dynamic HEIC. macOS reads the embedded
// apple_desktop:solar metadata and picks the right image based on the
// current sun position (computed from Location Services), so the
// wallpaper rotates natively and adapts when you travel.
//
// Two modes:
//
//   aerial-build-dynamic [--pack <Name>]
//       Reads the pack's frames from ~/Pictures/AerialWallpapers/
//       ("<pack>-<frame>.png", as written by aerial-extract-frames) and
//       writes "<Pack>-Dynamic.heic" alongside them. The pack's frames
//       and schedule come from ../scenes.json. Default: the first pack
//       in scenes.json whose frames are all on disk.
//
//   aerial-build-dynamic --images <morning> <day> <evening> <night> [--out <path>]
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
    case let other:
        fail("unknown argument: \(other)", code: 2)
    }
}

let dir = ("~/Pictures/AerialWallpapers" as NSString).expandingTildeInPath
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

// --- A scene is a set of named frames plus the schedule that maps them
// to the sun. A schedule lists frames in the order they appear, with the
// sun altitude (degrees) of each switch between them: "rising" covers
// solar midnight → noon, "setting" covers noon → midnight.
struct Schedule { let frames: [String]; let thresholds: [Double] }
struct Scene {
    let name: String
    let frames: [String: String]   // frame name → image path
    let rising: Schedule
    let setting: Schedule
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

let scene: Scene
let outFile: String
if !customImages.isEmpty {
    scene = Scene(
        name: "Custom",
        frames: Dictionary(uniqueKeysWithValues: zip(["morning", "day", "evening", "night"], customImages)),
        rising: Schedule(frames: ["night", "morning", "day"], thresholds: [-7, 10]),
        setting: Schedule(frames: ["day", "evening", "night"], thresholds: [3, -9]),
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
        light: light, dark: dark)
    outFile = outOverride ?? "\(dir)/\(name.filter { !$0.isWhitespace })-Dynamic.heic"
}

// --- Frame order in the HEIC: the light frame first, because image 0 is
// what thumbnails and non-dynamic viewers show; then by first appearance.
var order: [String] = []
for frame in [scene.light] + scene.rising.frames + scene.setting.frames + [scene.dark] where !order.contains(frame) {
    order.append(frame)
}
let unknown = order.filter { scene.frames[$0] == nil }
if !unknown.isEmpty {
    fail("\(scene.name): schedule uses frames the pack does not define: \(unknown.joined(separator: ", "))")
}
let unused = scene.frames.keys.filter { !order.contains($0) }.sorted()
if !unused.isEmpty {
    fail("\(scene.name): frames never shown by the schedule: \(unused.joined(separator: ", "))")
}
// The two schedules hand over to each other at solar noon and midnight.
// Keeping the frame the same across both handovers also means an anchor
// from the other side of the sky can never win with a different frame.
if scene.rising.frames.last != scene.setting.frames.first || scene.setting.frames.last != scene.rising.frames.first {
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
    let names = missingFrames.map { "\(scene.name) \($0.capitalized)" }.joined(separator: ", ")
    fail("""
        missing source frames for: \(missingFrames.joined(separator: ", "))

        Open System Settings → Wallpaper, click the cloud-arrow icon to download
        \(names), then re-run:  aerial-install --pack "\(scene.name)"

        """)
}

// --- Light/Dark appearance fallback. If a user forces Light or Dark mode
// (overriding Auto), macOS uses these indices instead of the solar table.
let appearance: [String: Int] = [
    "l": order.firstIndex(of: scene.light)!,
    "d": order.firstIndex(of: scene.dark)!,
]

// --- Encode the metadata as a base64 binary plist (Apple's format).
let plistData = try PropertyListSerialization.data(
    fromPropertyList: ["ap": appearance, "si": solar],
    format: .binary,
    options: 0)
let solarBase64 = plistData.base64EncodedString()

// --- Build the HEIC with apple_desktop:solar metadata on the primary image.
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
        "solar" as CFString,
        .string,
        solarBase64 as CFString) else {
    fail("metadata tag creation failed")
}
CGImageMetadataSetTagWithPath(metadata, nil, "apple_desktop:solar" as CFString, tag)

CGImageDestinationAddImageAndMetadata(dest, images[0], metadata, nil)
for img in images.dropFirst() {
    CGImageDestinationAddImage(dest, img, nil)
}
guard CGImageDestinationFinalize(dest) else {
    fail("HEIC finalize failed")
}

let bytes = (try? FileManager.default.attributesOfItem(atPath: outFile)[.size] as? Int) ?? 0
let mb = Double(bytes) / 1_048_576
print(String(format: "wrote %@ (%.1f MB, %d frames: %@, %d solar anchors)",
             outFile, mb, images.count, order.joined(separator: " "), solar.count))
