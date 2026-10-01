import Testing
@testable import TMT88VCore

struct UsbDescriptorParserTests {
    static let tmT88VPrinterClassConfiguration: [UInt8] = [
        0x09, 0x02, 0x20, 0x00, 0x01, 0x01, 0x00, 0xC0, 0x01,
        0x09, 0x04, 0x00, 0x00, 0x02, 0x07, 0x01, 0x02, 0x00,
        0x07, 0x05, 0x01, 0x02, 0x40, 0x00, 0x00,
        0x07, 0x05, 0x82, 0x02, 0x40, 0x00, 0x00,
    ]

    @Test func parsesCapturedTMT88VDescriptor() throws {
        let interfaces = UsbDescriptorParser.parseConfiguration(Self.tmT88VPrinterClassConfiguration)
        #expect(interfaces.count == 1)
        let interface = try #require(interfaces.first)
        #expect(interface.isPrinterClass)
        #expect(interface.classDescription == "Printer Class (bidirectional)")
        #expect(interface.endpoints.count == 2)

        let out = try #require(interface.bulkOut)
        #expect(out.address == 0x01)
        #expect(out.maxPacketSize == 64)

        let input = try #require(interface.bulkIn)
        #expect(input.address == 0x82)
        #expect(input.direction == .in)
        #expect(input.transferType == .bulk)
    }

    @Test func stopsOnTruncatedDescriptor() {
        let truncated = Array(Self.tmT88VPrinterClassConfiguration.prefix(22))
        let interfaces = UsbDescriptorParser.parseConfiguration(truncated)
        #expect(interfaces.count == 1)
        #expect(interfaces[0].endpoints.isEmpty)
    }

    @Test func ignoresZeroLengthDescriptor() {
        #expect(UsbDescriptorParser.parseConfiguration([0x00, 0x04, 0x00]).isEmpty)
    }

    @Test func recognisesVendorClassInterface() {
        let vendor: [UInt8] = [
            0x09, 0x04, 0x00, 0x00, 0x02, 0xFF, 0x00, 0x00, 0x00,
            0x07, 0x05, 0x02, 0x02, 0x40, 0x00, 0x00,
            0x07, 0x05, 0x81, 0x02, 0x40, 0x00, 0x00,
        ]
        let interface = UsbDescriptorParser.parseConfiguration(vendor)[0]
        #expect(interface.isVendorClass)
        #expect(interface.bulkOut?.address == 0x02)
        #expect(interface.bulkIn?.address == 0x81)
    }
}
