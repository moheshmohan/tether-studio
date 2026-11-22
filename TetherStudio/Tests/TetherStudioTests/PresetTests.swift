import XCTest
@testable import TetherStudio

final class PresetTests: XCTestCase {
    private func choice(_ leaf: String, _ current: String?, _ options: [String], readOnly: Bool = false) -> CameraConfig {
        CameraConfig(path: CameraService.path(forLeaf: leaf), label: leaf, type: "RADIO", readOnly: readOnly, current: current,
                     options: options.enumerated().map { ConfigOption(index: $0.offset, value: $0.element) },
                     bottom: nil, top: nil, step: nil)
    }

    private func range(_ leaf: String, _ current: Double, _ bottom: Double, _ top: Double, readOnly: Bool = false) -> CameraConfig {
        CameraConfig(path: CameraService.path(forLeaf: leaf), label: leaf, type: "RANGE", readOnly: readOnly,
                     current: String(current), options: [], bottom: bottom, top: top, step: 100)
    }

    // MARK: what a preset may touch

    func testEverythingAPresetCanSetIsOnTheWriteWhitelistAndIsRead() {
        for field in PresetCatalogue.fields {
            XCTAssertTrue(WritableConfig.allowed.contains(field.leaf), "\(field.leaf) is not whitelisted")
            XCTAssertTrue(CameraService.controlPaths.contains { CameraService.leaf(of: $0) == field.leaf },
                          "\(field.leaf) is not among the controls the app reads")
        }
        XCTAssertEqual(Set(PresetCatalogue.fields.map(\.leaf)).count, PresetCatalogue.fields.count)
    }

    func testPresetsCannotReachActionsOrAnythingOutsideTheCatalogue() {
        // Recording, focusing and the raw-opcode widget are not settings; a preset file naming them changes nothing.
        for leaf in ["movie", "autofocus", "manualfocus", "opcode", "capture", "d2ca", "d223"] {
            XCTAssertNil(PresetCatalogue.field(leaf), leaf)
        }
        let preset = Preset(id: "x", name: "x", settings: [PresetSetting("opcode", "0x9227"), PresetSetting("movie", "1"),
                                                         PresetSetting("iso", "100")])
        XCTAssertEqual(preset.ordered.map(\.leaf), ["iso"])
    }

    func testBuiltInsUseOnlyCatalogueSettingsAndHaveDistinctNames() {
        XCTAssertEqual(Set(Preset.builtIns.map(\.id)).count, Preset.builtIns.count)
        XCTAssertEqual(Set(Preset.builtIns.map(\.name)).count, Preset.builtIns.count)
        for preset in Preset.builtIns {
            XCTAssertTrue(preset.builtIn)
            XCTAssertFalse(preset.settings.isEmpty)
            XCTAssertEqual(preset.ordered.count, preset.settings.count, "\(preset.name) names a setting the app does not know")
            XCTAssertFalse(preset.settings.contains { $0.leaf == "f-number" }, "built-ins must not depend on the lens")
            for setting in preset.settings where setting.leaf == "d242" {
                for value in setting.values { XCTAssertFalse(MovieSettings.quality(value).hasPrefix("Setting"), value) }
            }
        }
    }

    func testSettingsAreSentInCatalogueOrderWhateverTheFileSays() {
        let preset = Preset(id: "x", name: "x", settings: [
            PresetSetting("d240", "2"), PresetSetting("colortemperature", "5600"), PresetSetting("d242", "33"),
            PresetSetting("whitebalance", "Choose Color Temperature"), PresetSetting("d23f", "0"),
            PresetSetting("shutterspeed", "1/50"), PresetSetting("d241", "8"), PresetSetting("expprogram", "Movie (M)"),
        ])
        XCTAssertEqual(preset.ordered.map(\.leaf),
                       ["expprogram", "d241", "d242", "whitebalance", "colortemperature", "shutterspeed", "d23f", "d240"])
    }

    // MARK: one setting

    func testAValueTheCameraShowsNeedsNothing() {
        let cfg = choice("iso", "Auto ISO", ["Auto ISO", "100", "200"])
        XCTAssertEqual(PresetPlan.step(for: PresetSetting("iso", "Auto ISO"), in: cfg), .already)
        // Also when the camera would not let it be changed.
        XCTAssertEqual(PresetPlan.step(for: PresetSetting("iso", "Auto ISO"), in: choice("iso", "Auto ISO", [], readOnly: true)), .already)
    }

    func testAChoiceIsFoundByItsTextNotItsPlace() {
        let cfg = choice("expprogram", "Movie (Scene)", ["P", "A", "Movie (P)", "Movie (M)", "Movie (Scene)"])
        XCTAssertEqual(PresetPlan.step(for: PresetSetting("expprogram", "Movie (M)"), in: cfg),
                       .choose(index: 3, value: "Movie (M)", nearest: false))
    }

    func testTheFirstAlternativeTheCameraHasIsTaken() {
        let setting = PresetSetting("d242", "33", "32")
        XCTAssertEqual(PresetPlan.step(for: setting, in: choice("d242", "36", ["33", "36"])), .choose(index: 0, value: "33", nearest: false))
        XCTAssertEqual(PresetPlan.step(for: setting, in: choice("d242", "35", ["32", "35"])), .choose(index: 0, value: "32", nearest: false))
        XCTAssertEqual(PresetPlan.step(for: setting, in: choice("d242", "32", ["32", "35"])), .already)
        XCTAssertEqual(PresetPlan.step(for: setting, in: choice("d242", "4", ["4", "25"])), .noSuchValue)
        // Any wanted value the camera shows already is kept, even when an earlier one is offered.
        XCTAssertEqual(PresetPlan.step(for: setting, in: choice("d242", "32", ["32", "33"])), .already)
    }

    func testLowLightGetsAFrameRateThatAllowsItsShutterInEitherFormat() {
        let lowLight = Preset.builtIns.first { $0.id == "builtin.lowlight" }!
        let quality = lowLight.settings.first { $0.leaf == "d242" }!
        // HD 100p (the camera's HD list as seen): 25p 50M is chosen.
        XCTAssertEqual(PresetPlan.step(for: quality, in: choice("d242", "29", ["4", "25", "5", "27", "29", "31"])),
                       .choose(index: 2, value: "5", nearest: false))
        // HD 25p 16M is already fine; 4K 25p 60M too.
        XCTAssertEqual(PresetPlan.step(for: quality, in: choice("d242", "27", ["4", "25", "5", "27", "29", "31"])), .already)
        XCTAssertEqual(PresetPlan.step(for: quality, in: choice("d242", "36", ["33", "36"])), .already)
        for value in quality.values { XCTAssertTrue(["25p", "30p", "24p"].contains { MovieSettings.quality(value).hasPrefix($0) }, value) }
    }

    func testWhatTheCameraSetsItselfIsLeftAlone() {
        XCTAssertEqual(PresetPlan.step(for: PresetSetting("shutterspeed", "1/50"), in: choice("shutterspeed", "1/100", ["1/50", "1/100"], readOnly: true)), .locked)
        XCTAssertEqual(PresetPlan.step(for: PresetSetting("shutterspeed", "1/50"), in: choice("shutterspeed", "", [])), .locked)
        XCTAssertEqual(PresetPlan.step(for: PresetSetting("colortemperature", "5600"), in: range("colortemperature", 5500, 2500, 9900, readOnly: true)), .locked)
        XCTAssertEqual(PresetPlan.step(for: PresetSetting("d23f", "3"), in: nil), .notOffered)
    }

    func testAnApertureTheLensDoesNotHaveGivesTheNearestOne() {
        let cfg = choice("f-number", "5.6", ["3.5", "4", "5.6", "8"])
        XCTAssertEqual(PresetPlan.step(for: PresetSetting("f-number", "1.8"), in: cfg), .choose(index: 0, value: "3.5", nearest: true))
        XCTAssertEqual(PresetPlan.step(for: PresetSetting("f-number", "5.4"), in: cfg), .already)
        let shutter = choice("shutterspeed", "1/250", ["1/25", "1/60", "1/250"])
        XCTAssertEqual(PresetPlan.step(for: PresetSetting("shutterspeed", "1/50"), in: shutter), .choose(index: 1, value: "1/60", nearest: true))
        // Words have no nearest value, and other settings are never approximated.
        XCTAssertEqual(PresetPlan.step(for: PresetSetting("iso", "Auto ISO"), in: choice("iso", "100", ["100", "200"])), .noSuchValue)
        XCTAssertEqual(PresetPlan.step(for: PresetSetting("d23f", "9"), in: choice("d23f", "0", ["0", "1", "2"])), .noSuchValue)
    }

    func testASliderValueIsKeptInsideTheCamerasRange() {
        let cfg = range("colortemperature", 5500, 2500, 9900)
        XCTAssertEqual(PresetPlan.step(for: PresetSetting("colortemperature", "5600"), in: cfg), .slide(value: 5600))
        XCTAssertEqual(PresetPlan.step(for: PresetSetting("colortemperature", "12000"), in: cfg), .slide(value: 9900))
        XCTAssertEqual(PresetPlan.step(for: PresetSetting("colortemperature", "5500"), in: cfg), .already)
        XCTAssertEqual(PresetPlan.step(for: PresetSetting("colortemperature", "warm"), in: cfg), .noSuchValue)
    }

    func testNumbersInTheCamerasWayOfWritingThem() {
        XCTAssertEqual(PresetPlan.number("1/50"), 0.02)
        XCTAssertEqual(PresetPlan.number("2.8"), 2.8)
        XCTAssertEqual(PresetPlan.number("F4"), 4)
        XCTAssertEqual(PresetPlan.number("f/5.6"), 5.6)
        XCTAssertEqual(PresetPlan.number("-0.7"), -0.7)
        XCTAssertEqual(PresetPlan.number("2\""), 2)
        XCTAssertNil(PresetPlan.number("Auto ISO"))
        XCTAssertNil(PresetPlan.number("Bulb"))
    }

    // MARK: saving the current settings

    private var camera: [String: CameraConfig] {
        [
            "expprogram": choice("expprogram", "Movie (S)", ["Movie (P)", "Movie (S)"]),
            "d241": choice("d241", "8", ["8", "9"]),
            "d242": choice("d242", "33", ["33", "36"]),
            "shutterspeed": choice("shutterspeed", "1/50", ["1/25", "1/50"]),
            "f-number": choice("f-number", "4", ["4"], readOnly: true),          // the camera picks it in Movie (S)
            "iso": choice("iso", "Auto ISO", ["Auto ISO", "100"]),
            "whitebalance": choice("whitebalance", "Choose Color Temperature", ["Automatic", "Choose Color Temperature"]),
            "colortemperature": range("colortemperature", 5600, 2500, 9900),
            "focusmode": choice("focusmode", "AF-C", ["AF-C", "Manual"]),
            "d240": choice("d240", "", [], readOnly: true),                       // locked by a picture profile
            "d23f": choice("d23f", "3", ["0", "1", "2", "3"]),
            "d21d": choice("d21d", "0", ["0", "1", "2"], readOnly: true),         // status, not a setting
        ]
    }

    func testSavingTakesWhatCanBeSetNowAndNothingElse() {
        let preset = Preset.capture(name: "Desk", from: camera)
        XCTAssertEqual(preset.ordered.map(\.leaf),
                       ["expprogram", "d241", "d242", "focusmode", "whitebalance", "colortemperature", "iso", "shutterspeed", "d23f"])
        XCTAssertEqual(preset.settings.first { $0.leaf == "colortemperature" }?.values, ["5600"])
        XCTAssertFalse(preset.builtIn)
        XCTAssertTrue(preset.matches(camera))
    }

    func testSavingOnlySomeGroups() {
        let colour = Preset.capture(name: "Colour", from: camera, groups: [.colour])
        XCTAssertEqual(colour.ordered.map(\.leaf), ["whitebalance", "colortemperature"])
        XCTAssertTrue(Preset.capture(name: "none", from: [:]).settings.isEmpty)
    }

    func testAPresetMatchesOnlyWhileTheCameraAgrees() {
        let preset = Preset.capture(name: "Desk", from: camera)
        var changed = camera
        changed["iso"] = choice("iso", "100", ["Auto ISO", "100"])
        XCTAssertFalse(preset.matches(changed))
        // A locked setting that shows another value counts against the preset (Movie (Scene) reads
        // white balance "Automatic" while a colour temperature is still stored)…
        var locked = camera
        locked["whitebalance"] = choice("whitebalance", "Automatic", ["Automatic"], readOnly: true)
        locked["colortemperature"] = range("colortemperature", 5600, 2500, 9900, readOnly: true)
        XCTAssertFalse(preset.matches(locked))
        XCTAssertFalse(Preset.builtIns.first { $0.id == "builtin.daylight" }!.matches(locked))
        // …one that shows no value at all, or is not listed, is left out…
        var silent = camera
        silent["shutterspeed"] = choice("shutterspeed", "", [], readOnly: true)
        silent["d23f"] = nil
        XCTAssertTrue(preset.matches(silent))
        // …and with nothing to compare there is no match.
        XCTAssertFalse(preset.matches([:]))
    }

    // MARK: the user's presets on disk

    func testOwnPresetsSurviveARestartAndASameNameReplaces() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("presets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(PresetLibrary.load(from: url), PresetLibrary())

        var library = PresetLibrary()
        library.put(Preset.capture(name: "Desk", from: camera))
        library.put(Preset.capture(name: "Colour", from: camera, groups: [.colour]))
        let firstID = library.presets[0].id
        library.put(Preset.capture(name: "desk", from: camera, groups: [.exposure]))
        XCTAssertEqual(library.presets.map(\.name), ["desk", "Colour"])
        XCTAssertEqual(library.presets[0].id, firstID)
        XCTAssertEqual(library.presets[0].ordered.map(\.leaf), ["iso", "shutterspeed"])

        library.save(to: url)
        XCTAssertEqual(PresetLibrary.load(from: url), library)
        library.remove(id: firstID)
        XCTAssertEqual(library.presets.map(\.name), ["Colour"])
    }

    func testABrokenPresetFileGivesAnEmptyLibraryNotACrash() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("presets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(PresetLibrary.load(from: url), PresetLibrary())
    }

    // MARK: the camera's clock

    func testTheClockTextIsLocalTimeWithTheOffsetFromUTC() {
        let date = Date(timeIntervalSince1970: 1_795_256_130)           // 2026-11-21 10:15:30 UTC
        XCTAssertEqual(CameraClock.text(date, zone: TimeZone(identifier: "Asia/Dubai")!), "20261121T141530.0+0400")
        XCTAssertEqual(CameraClock.text(date, zone: TimeZone(identifier: "UTC")!), "20261121T101530.0+0000")
        XCTAssertEqual(CameraClock.text(date, zone: TimeZone(identifier: "Asia/Kolkata")!), "20261121T154530.0+0530")
        XCTAssertEqual(CameraClock.text(date, zone: TimeZone(identifier: "America/St_Johns")!), "20261121T064530.0-0330")
        // Summer time is part of the offset: Berlin is +0100 in November and +0200 in July.
        XCTAssertEqual(CameraClock.text(date, zone: TimeZone(identifier: "Europe/Berlin")!), "20261121T111530.0+0100")
        let july = Date(timeIntervalSince1970: 1_783_937_730)           // 2026-07-13 10:15:30 UTC
        XCTAssertEqual(CameraClock.text(july, zone: TimeZone(identifier: "Europe/Berlin")!), "20260713T121530.0+0200")
        // Across midnight the date is the local one.
        XCTAssertEqual(CameraClock.text(date, zone: TimeZone(identifier: "Pacific/Auckland")!), "20261121T231530.0+1300")
    }

    func testTheClockIsWhitelistedButNoPresetCanCarryIt() {
        XCTAssertTrue(WritableConfig.allowed.contains(CameraClock.setting))
        XCTAssertNil(PresetCatalogue.field(CameraClock.setting))
    }

    // MARK: words

    func testWhiteBalanceShiftsInWords() {
        XCTAssertEqual(SettingNames.label(leaf: "d21c", value: "192"), "0")
        XCTAssertEqual(SettingNames.label(leaf: "d21c", value: "164"), "B7")
        XCTAssertEqual(SettingNames.label(leaf: "d21c", value: "220"), "A7")
        XCTAssertEqual(SettingNames.label(leaf: "d21c", value: "194"), "A0.5")
        XCTAssertEqual(SettingNames.label(leaf: "d210", value: "191"), "M0.25")
        XCTAssertEqual(SettingNames.label(leaf: "d210", value: "200"), "G2")
    }

    func testTheCamerasNumbersInWords() {
        XCTAssertEqual(SettingNames.label(leaf: "d23f", value: "0"), "Off")
        XCTAssertEqual(SettingNames.label(leaf: "d23f", value: "8"), "PP8")
        XCTAssertEqual(SettingNames.label(leaf: "d240", value: "13"), "Sepia")
        XCTAssertEqual(SettingNames.label(leaf: "d21b", value: "32768"), "Off")
        XCTAssertEqual(SettingNames.label(leaf: "d25f", value: "3"), "Clear Image Zoom")
        XCTAssertEqual(SettingNames.label(leaf: "d242", value: "33"), "25p 100M")
        XCTAssertEqual(SettingNames.label(leaf: "colortemperature", value: "5600"), "5600 K")
        XCTAssertEqual(SettingNames.label(leaf: "iso", value: "Auto ISO"), "Auto ISO")
    }

    func testTheReportSaysWhatWasNotSet() {
        var outcome = PresetOutcome(name: "Film look")
        outcome.set = ["Mode", "Shutter"]
        outcome.kept = 3
        outcome.seconds = 6.4
        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(outcome.text, "Film look: 2 set, 3 already right (6 s).")
        outcome.skipped = ["Aperture (the camera sets it itself in this mode)"]
        XCTAssertFalse(outcome.ok)
        XCTAssertTrue(outcome.text.hasSuffix("Not set: Aperture (the camera sets it itself in this mode)."))
        var nothing = PresetOutcome(name: "Auto 4K")
        nothing.kept = 12
        XCTAssertEqual(nothing.text, "Auto 4K: the camera already had all of it.")
    }
}
