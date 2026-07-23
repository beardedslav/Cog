import Foundation
import CoreAudio
import AppKit

final class AudioDeviceModel: ObservableObject {
    struct Device: Identifiable, Equatable {
        let id: Int      // AudioDeviceID stored as Int for UserDefaults compatibility
        let name: String
        let isAirPlay: Bool
        var isDiscoveredOnly: Bool = false   // Bonjour-only; selecting arms the pending switch
    }

    private var isActive = true
    private var observers: [NSObjectProtocol] = []
    // Set around programmatic refreshes (loadSelection); a programmatic
    // assignment must never persist or arm — only a user pick may.
    private var isProgrammaticUpdate = false
    private var lastSeenOutputDevice: NSDictionary?

    @Published var devices: [Device] = []
    @Published var selectedDeviceID: Int = -1 {
        didSet {
            guard isActive, !isProgrammaticUpdate else { return }
            if let picked = devices.first(where: { $0.id == selectedDeviceID }), picked.isDiscoveredOnly {
                AirPlayServiceBrowser.shared().armPendingSwitch(forDeviceName: picked.name)
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.sound")!)
                // Snap back to the stored selection; the browser writes the
                // real device once it materializes.
                loadSelection(from: devices)
                return
            }
            saveSelection()
        }
    }

    deinit { isActive = false }

    init() {
        loadDevices()
    }

    func startObserving() {
        guard observers.isEmpty else { return }
        AirPlayServiceBrowser.shared().beginBrowsing()
        lastSeenOutputDevice = UserDefaults.standard.dictionary(forKey: "outputDevice").map { $0 as NSDictionary }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSNotification.Name("AirPlayServiceBrowserDidUpdateNotification"),
            object: nil, queue: .main) { [weak self] _ in self?.loadDevices() })
        // React only when outputDevice actually changed (e.g. the browser wrote
        // a freshly materialized sink). Re-enumerate so the new device is found
        // by ID; loadSelection on a stale list would fall through and clobber.
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                let current = UserDefaults.standard.dictionary(forKey: "outputDevice").map { $0 as NSDictionary }
                guard current != self.lastSeenOutputDevice else { return }
                self.lastSeenOutputDevice = current
                self.loadDevices()
            })
    }

    func stopObserving() {
        AirPlayServiceBrowser.shared().endBrowsingSoon()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    private var elementMain: AudioObjectPropertyElement {
        if #available(macOS 12.0, *) {
            return kAudioObjectPropertyElementMain
        } else {
            return kAudioObjectPropertyElementMaster  // deprecated but needed for <12
        }
    }

    func loadDevices() {
        var result: [Device] = [Device(id: -1, name: NSLocalizedString("System Default Device", comment: ""), isAirPlay: false)]

        // Get all device IDs
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: elementMain
        )
        var propSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &propSize) == noErr else {
            devices = result; loadSelection(from: result); return
        }

        let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &propSize, &deviceIDs) == noErr else {
            devices = result; loadSelection(from: result); return
        }

        for deviceID in deviceIDs {
            guard let name = deviceName(deviceID) else { continue }
            guard hasOutputStreams(deviceID) else { continue }
            result.append(Device(id: Int(deviceID), name: name,
                                 isAirPlay: transportType(deviceID) == kAudioDeviceTransportTypeAirPlay))
        }

        let materialized = Set(result.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() })
        let discovered = AirPlayServiceBrowser.shared().discoveredNames
        for (index, name) in discovered.enumerated() {
            let key = name.trimmingCharacters(in: .whitespaces).lowercased()
            if materialized.contains(key) { continue }
            result.append(Device(id: -(1000 + index), name: name, isAirPlay: true, isDiscoveredOnly: true))
        }

        devices = result
        loadSelection(from: result)
    }

    private func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: elementMain
        )
        var cfName: CFString? = nil
        let status = withUnsafeMutablePointer(to: &cfName) { ptr in
            AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize,
                                       UnsafeMutableRawPointer(ptr))
        }
        guard status == noErr, let name = cfName as String? else { return nil }
        return name
    }

    private func hasOutputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var bufSize: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: elementMain
        )
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &bufSize) == noErr,
              bufSize >= MemoryLayout<UInt32>.size else { return false }

        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(bufSize),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &bufSize, ptr) == noErr else { return false }
        return ptr.bindMemory(to: AudioBufferList.self, capacity: 1).pointee.mNumberBuffers > 0
    }

    private func transportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: elementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport) == noErr else { return 0 }
        return transport
    }

    // Programmatic refresh only: assigns selectedDeviceID without persisting or
    // arming. Persistence stays with user picks (selectedDeviceID's didSet);
    // re-affirming a stored value here would let a stale-list fall-through write
    // {"", -1} and, during arming, disarm the pending switch.
    private func loadSelection(from deviceList: [Device]) {
        isProgrammaticUpdate = true
        defer { isProgrammaticUpdate = false }

        let stored = UserDefaults.standard.dictionary(forKey: "outputDevice")
        let storedID = (stored?["deviceID"] as? NSNumber)?.intValue ?? -1
        let storedName = stored?["name"] as? String ?? ""

        if storedID == -1 {
            selectedDeviceID = -1
            return
        }
        if deviceList.contains(where: { $0.id == storedID }) {
            selectedDeviceID = storedID
        } else if let match = deviceList.first(where: { $0.name == storedName && !$0.isDiscoveredOnly }) {
            // Discovered-only devices are excluded here: assigning their
            // synthetic id would re-enter selectedDeviceID's didSet on the
            // isDiscoveredOnly branch and recurse into loadSelection forever.
            selectedDeviceID = match.id
        } else {
            selectedDeviceID = -1
        }
    }

    private func saveSelection() {
        guard !devices.isEmpty else { return }
        let name = devices.first(where: { $0.id == selectedDeviceID })?.name ?? ""
        saveSelection(deviceID: selectedDeviceID, name: name)
    }

    private func saveSelection(deviceID: Int, name: String) {
        UserDefaults.standard.set(["name": name, "deviceID": deviceID], forKey: "outputDevice")
    }
}
