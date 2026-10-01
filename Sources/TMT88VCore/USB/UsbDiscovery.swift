import Foundation
import IOKit
import IOUSBHost

public enum UsbDiscovery {
    public static func devices(vendorID: UInt16, readEndpoints: Bool = true) -> [UsbDeviceInfo] {
        let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        matching["IOPropertyMatch"] = ["idVendor": Int(vendorID)]

        let services = IORegistry.services(matching: matching)
        defer { services.forEach { IOObjectRelease($0) } }

        return services
            .map { deviceInfo(for: $0, readEndpoints: readEndpoints) }
            .sorted { ($0.locationID ?? 0) < ($1.locationID ?? 0) }
    }

    public static func printers(model: PrinterModel, readEndpoints: Bool = true) -> [UsbDeviceInfo] {
        devices(vendorID: model.usbVendorID, readEndpoints: readEndpoints)
            .filter { model.matches(productName: $0.productName) }
    }

    public static func selectPrinter(model: PrinterModel, serial: String?) throws -> UsbDeviceInfo {
        let candidates = printers(model: model, readEndpoints: false)
        if let serial {
            guard let match = candidates.first(where: { $0.serialNumber == serial }) else {
                throw UsbError(.printerNotFound, "no \(model.name) with serial \(serial); found \(candidates.count) other(s)")
            }
            return match
        }
        guard let first = candidates.first else {
            throw UsbError(.printerNotFound, "no USB device with vendor 0x\(Hex.word(model.usbVendorID)) and product name \(model.usbProductNames) is connected")
        }
        return first
    }

    static func interfaceServices(ofDevice registryID: UInt64) -> [io_service_t] {
        guard let device = IORegistry.service(registryID: registryID) else { return [] }
        defer { IOObjectRelease(device) }
        var result: [io_service_t] = []
        for child in IORegistry.children(of: device) {
            if IORegistry.conforms(child, to: "IOUSBHostInterface") {
                result.append(child)
            } else {
                IOObjectRelease(child)
            }
        }
        return result
    }

    private static func deviceInfo(for service: io_service_t, readEndpoints: Bool) -> UsbDeviceInfo {
        let registryID = IORegistry.registryID(of: service)
        let interfaces = interfaceServices(ofDevice: registryID)
        defer { interfaces.forEach { IOObjectRelease($0) } }

        return UsbDeviceInfo(
            registryID: registryID,
            vendorID: UInt16(truncatingIfNeeded: IORegistry.int(service, "idVendor") ?? 0),
            productID: UInt16(truncatingIfNeeded: IORegistry.int(service, "idProduct") ?? 0),
            manufacturer: IORegistry.string(service, "kUSBVendorString") ?? IORegistry.string(service, "USB Vendor Name"),
            productName: IORegistry.string(service, "kUSBProductString") ?? IORegistry.string(service, "USB Product Name"),
            serialNumber: IORegistry.string(service, "kUSBSerialNumberString") ?? IORegistry.string(service, "USB Serial Number"),
            locationID: IORegistry.int(service, "locationID").map { UInt32(truncatingIfNeeded: $0) },
            bcdUSB: IORegistry.int(service, "bcdUSB").map { UInt16(truncatingIfNeeded: $0) },
            linkSpeedBitsPerSecond: IORegistry.int(service, "UsbLinkSpeed"),
            interfaces: interfaces.map { interfaceSummary(for: $0, readEndpoints: readEndpoints) }
                .sorted { $0.info.number < $1.info.number }
        )
    }

    private static func interfaceSummary(for service: io_service_t, readEndpoints: Bool) -> UsbInterfaceSummary {
        let registryInfo = UsbInterfaceInfo(
            number: UInt8(truncatingIfNeeded: IORegistry.int(service, "bInterfaceNumber") ?? 0),
            alternateSetting: UInt8(truncatingIfNeeded: IORegistry.int(service, "bAlternateSetting") ?? 0),
            interfaceClass: UInt8(truncatingIfNeeded: IORegistry.int(service, "bInterfaceClass") ?? 0),
            interfaceSubClass: UInt8(truncatingIfNeeded: IORegistry.int(service, "bInterfaceSubClass") ?? 0),
            interfaceProtocol: UInt8(truncatingIfNeeded: IORegistry.int(service, "bInterfaceProtocol") ?? 0),
            endpoints: []
        )
        let owners = IORegistry.userClientOwners(of: service)
        var summary = UsbInterfaceSummary(info: registryInfo, endpointsReadable: false, endpointError: nil, openedBy: owners)
        guard readEndpoints else { return summary }

        do {
            let parsed = try readDescriptors(service: service)
            if let match = parsed.first(where: { $0.number == registryInfo.number && $0.alternateSetting == registryInfo.alternateSetting }) {
                summary.info = match
                summary.endpointsReadable = true
            } else {
                summary.endpointError = "interface \(registryInfo.number) missing from configuration descriptor"
            }
        } catch let error as UsbError {
            summary.endpointError = error.description
        } catch {
            summary.endpointError = "\(error)"
        }
        return summary
    }

    private static func readDescriptors(service: io_service_t) throws -> [UsbInterfaceInfo] {
        let interface = try UsbInterfaceOpener.open(service: service, interestHandler: nil)
        defer { interface.destroy() }
        let configuration = interface.configurationDescriptor
        let length = Int(configuration.pointee.wTotalLength)
        let bytes = [UInt8](UnsafeRawBufferPointer(start: UnsafeRawPointer(configuration), count: length))
        return UsbDescriptorParser.parseConfiguration(bytes)
    }
}

enum UsbInterfaceOpener {
    static func open(service: io_service_t, interestHandler: IOUSBHostInterestHandler?) throws -> IOUSBHostInterface {
        do {
            return try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: interestHandler)
        } catch {
            let owners = IORegistry.userClientOwners(of: service)
            if !owners.isEmpty {
                let nsError = error as NSError
                throw UsbError(
                    .interfaceBusy,
                    "interface already opened by \(owners.joined(separator: ", "))",
                    ioReturn: IOReturn(truncatingIfNeeded: nsError.code)
                )
            }
            throw UsbError.from(error, fallback: .openFailed, context: "IOUSBHostInterface open failed")
        }
    }
}
