import Foundation
import TMT88VCore

setlinebuf(stdout)

let usage = """
usage: tmt88v-diag [--all] [--status] [--no-open]

  --all       list every USB device from the model's vendor, not only TM-T88V matches
  --status    query real-time printer status (DLE EOT) over bulk IN
  --no-open   read IORegistry only; do not open interfaces (endpoints unavailable)
"""

let arguments = Set(CommandLine.arguments.dropFirst())
if arguments.contains("-h") || arguments.contains("--help") {
    print(usage)
    exit(0)
}
let unknown = arguments.subtracting(["--all", "--status", "--no-open"])
guard unknown.isEmpty else {
    FileHandle.standardError.write("unknown argument(s): \(unknown.sorted().joined(separator: " "))\n\(usage)\n".data(using: .utf8)!)
    exit(2)
}

let model = PrinterModel.tmT88V80mm
let readEndpoints = !arguments.contains("--no-open")
let devices = arguments.contains("--all")
    ? UsbDiscovery.devices(vendorID: model.usbVendorID, readEndpoints: readEndpoints)
    : UsbDiscovery.printers(model: model, readEndpoints: readEndpoints)

guard !devices.isEmpty else {
    print("printer_not_found: no USB device matching vendor 0x\(String(format: "%04X", model.usbVendorID)) product \(model.usbProductNames)")
    exit(UsbErrorCode.printerNotFound.exitCode)
}

func hex8(_ value: UInt8) -> String { String(format: "0x%02X", value) }
func hex16(_ value: UInt16) -> String { String(format: "0x%04X", value) }
func field(_ label: String, _ value: String, indent: Int = 0) {
    let pad = String(repeating: " ", count: indent)
    print(pad + (label + ":").padding(toLength: 16 - indent, withPad: " ", startingAt: 0) + value)
}

var exitCode: Int32 = 0

for (index, device) in devices.enumerated() {
    if index > 0 { print() }
    let isTarget = model.matches(productName: device.productName)
    print(isTarget ? "TM-T88V detected" : "Epson device (not a TM-T88V match)")
    print()
    field("Vendor ID", hex16(device.vendorID))
    field("Product ID", hex16(device.productID))
    field("Manufacturer", device.manufacturer ?? "(none)")
    field("Product", device.productName ?? "(none)")
    field("Serial", device.serialNumber ?? "(not reported)")
    field("USB Mode", device.usbMode)
    if let location = device.locationID { field("Location ID", String(format: "0x%08X", location)) }
    if let bcd = device.bcdUSB { field("bcdUSB", String(format: "%X.%02X", bcd >> 8, bcd & 0xFF)) }
    if let speed = device.linkSpeedBitsPerSecond { field("Link speed", "\(speed / 1_000_000) Mbit/s") }
    field("Registry ID", String(format: "0x%llX", device.registryID))

    for summary in device.interfaces {
        let info = summary.info
        print()
        field("Interface", "\(info.number) (alt \(info.alternateSetting))")
        field("Class", "\(hex8(info.interfaceClass))/\(hex8(info.interfaceSubClass))/\(hex8(info.interfaceProtocol)) \(info.classDescription)", indent: 2)
        if !summary.openedBy.isEmpty {
            field("Opened by", summary.openedBy.joined(separator: ", "), indent: 2)
        }
        if let error = summary.endpointError {
            field("Endpoints", "unavailable - \(error)", indent: 2)
            exitCode = max(exitCode, 1)
            continue
        }
        if !summary.endpointsReadable {
            field("Endpoints", "not read (--no-open)", indent: 2)
            continue
        }
        if let out = info.bulkOut { field("Bulk OUT", "\(hex8(out.address)) maxPacket \(out.maxPacketSize)", indent: 2) }
        if let input = info.bulkIn { field("Bulk IN", "\(hex8(input.address)) maxPacket \(input.maxPacketSize)", indent: 2) }
        for endpoint in info.endpoints {
            field("Endpoint", "\(hex8(endpoint.address)) \(endpoint.direction.rawValue) \(endpoint.transferType.rawValue) maxPacket \(endpoint.maxPacketSize) interval \(endpoint.interval)", indent: 2)
        }
    }

    guard isTarget, readEndpoints else { continue }

    print()
    do {
        let transport = try IOUSBHostTransport.open(device: device)
        defer { transport.close() }
        field("Opened", "interface \(transport.interfaceInfo.number) via IOUSBHost (user space)")
        if transport.interfaceInfo.isPrinterClass {
            do {
                field("IEEE 1284 ID", try transport.ieee1284DeviceID())
                let port = try transport.portStatus()
                let flags = [
                    port & 0x20 != 0 ? "paper-empty" : nil,
                    port & 0x10 != 0 ? "selected" : nil,
                    port & 0x08 == 0 ? "error" : nil,
                ].compactMap { $0 }
                field("Port status", "\(hex8(port)) \(flags.isEmpty ? "-" : flags.joined(separator: ", "))")
            } catch {
                field("Class request", "\(error)")
            }
        }
        if arguments.contains("--status") {
            do {
                field("ESC/POS status", try PrinterStatusQuery.query(transport).summary)
            } catch {
                field("ESC/POS status", "\(error)")
                exitCode = max(exitCode, 1)
            }
        }
    } catch let error as UsbError {
        field("Open", error.description)
        exitCode = max(exitCode, error.code.exitCode)
    }
}

exit(exitCode)
