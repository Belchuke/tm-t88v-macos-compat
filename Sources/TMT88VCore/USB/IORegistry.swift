import Foundation
import IOKit

enum IORegistry {
    static func services(matching dictionary: CFDictionary) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, dictionary, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        return collect(iterator)
    }

    static func children(of entry: io_registry_entry_t) -> [io_registry_entry_t] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        return collect(iterator)
    }

    static func service(registryID: UInt64) -> io_service_t? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
        return service == 0 ? nil : service
    }

    static func registryID(of entry: io_registry_entry_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        return id
    }

    static func conforms(_ entry: io_registry_entry_t, to className: String) -> Bool {
        IOObjectConformsTo(entry, className) != 0
    }

    static func className(of entry: io_registry_entry_t) -> String {
        IOObjectCopyClass(entry)?.takeRetainedValue() as String? ?? "?"
    }

    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func string(_ entry: io_registry_entry_t, _ key: String) -> String? {
        property(entry, key) as? String
    }

    static func int(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        (property(entry, key) as? NSNumber)?.intValue
    }

    static func userClientOwners(of entry: io_registry_entry_t) -> [String] {
        let kids = children(of: entry)
        defer { kids.forEach { IOObjectRelease($0) } }
        let ownPrefix = "pid \(getpid()),"
        return kids
            .map { string($0, "IOUserClientCreator") ?? "driver \(className(of: $0))" }
            .filter { !$0.hasPrefix(ownPrefix) }
    }

    private static func collect(_ iterator: io_iterator_t) -> [io_object_t] {
        var result: [io_object_t] = []
        while case let object = IOIteratorNext(iterator), object != 0 {
            result.append(object)
        }
        return result
    }
}
