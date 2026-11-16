import XCTest
@testable import PowerKit

/// The Sound icon in the menu bar: which glyph for which volume and which output.
final class SoundIconTests: XCTestCase {

    func testMutedAlwaysShowsTheSlashedSpeakerOnSpeakers() {
        XCTAssertEqual(SoundIcon.symbol(volume: 0.8, muted: true, output: .speakers), "speaker.slash.fill")
    }

    func testBandsOnSpeakers() {
        XCTAssertEqual(SoundIcon.symbol(volume: 0.0, muted: false, output: .speakers), "speaker.fill")
        XCTAssertEqual(SoundIcon.symbol(volume: 0.2, muted: false, output: .speakers), "speaker.wave.1.fill")
        XCTAssertEqual(SoundIcon.symbol(volume: 0.5, muted: false, output: .speakers), "speaker.wave.2.fill")
        XCTAssertEqual(SoundIcon.symbol(volume: 0.9, muted: false, output: .speakers), "speaker.wave.3.fill")
    }

    func testAirPodsShowTheirOwnGlyphAtAnyVolume() {
        XCTAssertEqual(SoundIcon.symbol(volume: 0.1, muted: false, output: .airpodsPro), "airpods.pro")
        XCTAssertEqual(SoundIcon.symbol(volume: 0.9, muted: true, output: .airpodsPro), "airpods.pro")
        XCTAssertEqual(SoundIcon.symbol(volume: 0.5, muted: false, output: .airpods), "airpods")
    }

    func testGuessFromNameAndTransport() {
        XCTAssertEqual(OutputKind.guess(name: "MacBook Pro Speakers", transport: "bltn"), .speakers)
        XCTAssertEqual(OutputKind.guess(name: "Test AirPods Pro", transport: "blue"), .airpodsPro)
        XCTAssertEqual(OutputKind.guess(name: "Test AirPods Max", transport: "blue"), .airpodsMax)
        XCTAssertEqual(OutputKind.guess(name: "Some Headset", transport: "blue"), .headphones)
        XCTAssertEqual(OutputKind.guess(name: "Living Room Speaker", transport: "airp"), .hifi)
        XCTAssertEqual(OutputKind.guess(name: "Den TV", transport: "airp"), .display)
        XCTAssertEqual(OutputKind.guess(name: "Kitchen", transport: "airp"), .airplay)
    }

    func testOtherKindsOfOutput() {
        // The jack with headphones in it keeps the built-in transport but is not the laptop's speakers.
        XCTAssertEqual(OutputKind.guess(name: "External Headphones", transport: "bltn"), .headphones)
        // Bluetooth is not always headphones.
        XCTAssertEqual(OutputKind.guess(name: "JBL Flip 6", transport: "blue"), .hifi)
        XCTAssertEqual(OutputKind.guess(name: "Kitchen Sonos Roam", transport: "blue"), .hifi)
        XCTAssertEqual(OutputKind.guess(name: "Bose QC Ultra", transport: "blue"), .headphones)
        XCTAssertEqual(OutputKind.guess(name: "LG UltraFine Display", transport: "hdmi"), .display)
        XCTAssertEqual(OutputKind.guess(name: "DELL U2723QE", transport: "dprt"), .display)
        XCTAssertEqual(OutputKind.guess(name: "USB PnP Sound Device", transport: "usb "), .hifi)
        XCTAssertEqual(OutputKind.guess(name: "Logitech USB Headset", transport: "usb "), .headphones)
        XCTAssertEqual(OutputKind.guess(name: "Studio Display Speakers", transport: "usb "), .display)
        XCTAssertEqual(OutputKind.guess(name: "BlackHole 2ch", transport: "virt"), .other)
    }

    func testAMacOnTheNetworkShowsAsAComputer() {
        XCTAssertEqual(OutputKind.guess(name: "Colton’s MacBook Air", transport: "airp"), .speakers)
        XCTAssertEqual(OutputKind.guess(name: "Studio iMac", transport: "airp"), .display)
        XCTAssertEqual(OutputKind.guess(name: "Office Mac mini", transport: "airp"), .display)
    }

    func testAirPodsMaxHasItsOwnIcon() {
        XCTAssertEqual(OutputKind.guess(name: "My Ears", transport: "blue", productID: 8202), .airpodsMax)
        XCTAssertEqual(SoundIcon.symbol(volume: 0.5, muted: false, output: .airpodsMax), "airpods.max")
    }

    func testProductIDBeatsAnOwnerChosenName() {
        XCTAssertEqual(OutputKind.guess(name: "My Ears", transport: "blue", productID: 8228), .airpodsPro)
        XCTAssertEqual(OutputKind.guess(name: "My Ears", transport: "blue", productID: nil), .headphones)
    }
}

/// AirPods Max have one battery and no case, but they are AirPods all the same.
final class AirPodsMaxModelTests: XCTestCase {
    func testAirPodsMaxGetTheirBatteryAndTheirSettingsButton() {
        let outputs = [OutputDevice(id: "builtin", name: "MacBook Pro Speakers", kind: .speakers),
                       OutputDevice(id: "max", name: "Test AirPods Max", kind: .airpodsMax)]
        let battery = AccessoryBattery.parse([["Type": "Accessory Source", "Group Identifier": "G", "Current Capacity": 90]])
        let m = SoundMenuModel.merge(outputs: outputs, defaultID: "max", volume: 0.5, muted: false, batteries: battery, apple: nil)
        XCTAssertEqual(m.devices.first { $0.name == "Test AirPods Max" }?.battery?.left, 90)
        XCTAssertEqual(m.footerTitles, ["Test AirPods Max Settings…", "Sound Settings…"])
    }
}
