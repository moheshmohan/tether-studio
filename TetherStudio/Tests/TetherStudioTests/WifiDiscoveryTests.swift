import XCTest
@testable import TetherStudio

final class WifiDiscoveryTests: XCTestCase {

    // Shapes taken from the description documents of a real ZV-E10 (firmware 2.03).
    private let dd = """
    <?xml version="1.0"?>
    <root xmlns="urn:schemas-upnp-org:device-1-0">
      <device>
        <deviceType>urn:schemas-upnp-org:device:Basic:1</deviceType>
        <friendlyName>ZV-E10</friendlyName>
        <manufacturer>Sony Corporation</manufacturer>
        <serviceList><service>
          <serviceType>urn:schemas-sony-com:service:DigitalImaging:1</serviceType>
          <SCPDURL>/DigitalImagingDesc.xml</SCPDURL>
        </service></serviceList>
      </device>
    </root>
    """

    private func capabilities(mediaServer: String) -> String {
        """
        <scpd><X_DigitalImagingDeviceInfo>
          <X_ServerType>Control with Smartphone</X_ServerType>
          <X_PTP_MediaServerSupport>\(mediaServer)</X_PTP_MediaServerSupport>
          <X_PTP_RemoteControlSupport>Enable</X_PTP_RemoteControlSupport>
        </X_DigitalImagingDeviceInfo></scpd>
        """
    }

    func testLocationGivesHostPortAndPath() {
        let loc = WifiDiscovery.parseLocation("http://192.168.1.69:64321/dd.xml\r")
        XCTAssertEqual(loc?.host, "192.168.1.69")
        XCTAssertEqual(loc?.port, 64321)
        XCTAssertEqual(loc?.path, "/dd.xml")
    }

    func testLocationWithoutPortOrPath() {
        let loc = WifiDiscovery.parseLocation("http://10.0.0.7")
        XCTAssertEqual(loc?.port, 80)
        XCTAssertEqual(loc?.path, "/")
    }

    func testLocationRejectsWhatIsNotAnHTTPAddress() {
        XCTAssertNil(WifiDiscovery.parseLocation(""))
        XCTAssertNil(WifiDiscovery.parseLocation("not a url"))
        XCTAssertNil(WifiDiscovery.parseLocation("ftp://192.168.1.69/dd.xml"))
    }

    func testModelNameAndCapabilityDocument() {
        XCTAssertEqual(WifiDiscovery.friendlyName(in: dd), "ZV-E10")
        XCTAssertEqual(WifiDiscovery.capabilityPath(in: dd), "/DigitalImagingDesc.xml")
        XCTAssertEqual(WifiDiscovery.friendlyName(in: "<root/>"), "")
        XCTAssertNil(WifiDiscovery.capabilityPath(in: "<root/>"))
    }

    func testCapabilityDocumentGivenAsFullAddressOrWithoutSlash() {
        XCTAssertEqual(WifiDiscovery.capabilityPath(in: "<SCPDURL>http://192.168.1.69:64321/a/b.xml</SCPDURL>"), "/a/b.xml")
        XCTAssertEqual(WifiDiscovery.capabilityPath(in: "<SCPDURL>b.xml</SCPDURL>"), "/b.xml")
    }

    func testPCRemoteIsToldFromSmartphoneConnect() {
        XCTAssertEqual(WifiDiscovery.service(in: dd + capabilities(mediaServer: "Disable")), .pcRemote)
        XCTAssertEqual(WifiDiscovery.service(in: dd + capabilities(mediaServer: "Enable")), .smartphone)
        XCTAssertEqual(WifiDiscovery.service(in: dd), .unknown)
    }
}
