import CoreBluetooth
import Foundation

public let instamicServiceUUID = CBUUID(string: "FF10")
public let instamicNotifyUUID = CBUUID(string: "FF11")

public enum BLEState: Equatable {
    case poweredOff
    case unauthorized
    case unsupported
    case scanning
    case connecting(String)
    case connected(String)
    case disconnected(String?)
}

/// Everything the client reports back. The CLI prints these; the menu bar app
/// will render them as state plus a "last event" line.
public protocol BLEClientDelegate: AnyObject {
    func bleStateChanged(_ state: BLEState)
    /// Every advertisement seen while scanning. Used for discovery diagnostics —
    /// this is how we tell "device is in HFP mode" from "device isn't advertising".
    func bleDidSee(peripheral: CBPeripheral, advertisement: [String: Any], rssi: NSNumber)
    func bleDidReceive(frame: Frame, event: RecordEvent, raw: [UInt8])
    func bleDidReceiveMalformed(raw: [UInt8], error: FrameError)
    func bleLog(_ message: String)
}

public extension BLEClientDelegate {
    func bleDidSee(peripheral: CBPeripheral, advertisement: [String: Any], rssi: NSNumber) {}
    func bleDidReceiveMalformed(raw: [UInt8], error: FrameError) {}
    func bleLog(_ message: String) {}
}

/// Connects to the Instamic in Remote Control Mode and streams decoded frames.
///
/// Matching is by advertised service UUID or local name, never by address — the
/// device uses a resolvable private address that rotates (handoff §3).
public final class BLEClient: NSObject {
    public weak var delegate: BLEClientDelegate?

    /// Scan for every peripheral rather than filtering on FF10 in the scan call.
    /// Filtering server-side is more efficient, but a device that doesn't put
    /// FF10 in its advertising packet becomes invisible — and we have no capture
    /// of the advertisement, only of the GATT table. Scanning wide and filtering
    /// locally trades a little CPU for not silently finding nothing.
    public var scanWide: Bool = true
    /// Log every advertisement seen, not just matches.
    public var verbose: Bool = false
    public var autoReconnect: Bool = true
    /// When false, matching advertisements are reported but never connected to.
    /// Used by `ramble-sniff --scan-only` to answer "is it advertising at all?"
    /// without taking the device's single central slot.
    public var connectOnMatch: Bool = true

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var notifyCharacteristic: CBCharacteristic?
    private var reconnectDelay: TimeInterval = 1
    private var seenAdvertisements = Set<UUID>()

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    public func start() {
        guard central.state == .poweredOn else { return }
        beginScan()
    }

    public func stop() {
        central.stopScan()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    private func beginScan() {
        seenAdvertisements.removeAll()
        delegate?.bleStateChanged(.scanning)
        let services: [CBUUID]? = scanWide ? nil : [instamicServiceUUID]
        central.scanForPeripherals(
            withServices: services,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    /// Does this advertisement look like our device?
    private func matches(peripheral: CBPeripheral, advertisement: [String: Any]) -> Bool {
        if let uuids = advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
           uuids.contains(instamicServiceUUID) {
            return true
        }
        let names = [
            advertisement[CBAdvertisementDataLocalNameKey] as? String,
            peripheral.name,
        ].compactMap { $0 }
        return names.contains { $0.localizedCaseInsensitiveContains("instamic") }
    }

    private func scheduleReconnect() {
        guard autoReconnect else { return }
        let delay = reconnectDelay
        delegate?.bleLog(String(format: "reconnecting in %.0fs", delay))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.central.state == .poweredOn else { return }
            self.beginScan()
        }
        reconnectDelay = min(reconnectDelay * 2, 30)
    }
}

extension BLEClient: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            delegate?.bleLog("bluetooth powered on")
            beginScan()
        case .poweredOff:
            delegate?.bleStateChanged(.poweredOff)
        case .unauthorized:
            delegate?.bleStateChanged(.unauthorized)
        case .unsupported:
            delegate?.bleStateChanged(.unsupported)
        default:
            delegate?.bleLog("bluetooth state: \(central.state.rawValue)")
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let isNew = seenAdvertisements.insert(peripheral.identifier).inserted
        if verbose && isNew {
            delegate?.bleDidSee(peripheral: peripheral, advertisement: advertisementData, rssi: RSSI)
        }
        guard matches(peripheral: peripheral, advertisement: advertisementData) else { return }

        guard connectOnMatch else {
            delegate?.bleLog("MATCH: \(peripheral.name ?? "?") (\(peripheral.identifier)) rssi \(RSSI)")
            return
        }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        let name = peripheral.name ?? "Instamic"
        delegate?.bleStateChanged(.connecting(name))
        delegate?.bleLog("found \(name) (\(peripheral.identifier)) rssi \(RSSI)")
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        reconnectDelay = 1
        delegate?.bleStateChanged(.connected(peripheral.name ?? "Instamic"))
        peripheral.discoverServices([instamicServiceUUID])
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        delegate?.bleLog("connect failed: \(error?.localizedDescription ?? "unknown")")
        scheduleReconnect()
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        notifyCharacteristic = nil
        self.peripheral = nil
        delegate?.bleStateChanged(.disconnected(error?.localizedDescription))
        scheduleReconnect()
    }
}

extension BLEClient: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            delegate?.bleLog("service discovery failed: \(error.localizedDescription)")
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == instamicServiceUUID }) else {
            delegate?.bleLog("FF10 not present — is this the right device?")
            return
        }
        peripheral.discoverCharacteristics([instamicNotifyUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        if let error {
            delegate?.bleLog("characteristic discovery failed: \(error.localizedDescription)")
            return
        }
        guard let ch = service.characteristics?.first(where: { $0.uuid == instamicNotifyUUID }) else {
            delegate?.bleLog("FF11 not found on FF10")
            return
        }
        notifyCharacteristic = ch
        peripheral.setNotifyValue(true, for: ch)
        delegate?.bleLog("subscribed to FF11 — press the record button")
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard let data = characteristic.value else { return }
        let raw = [UInt8](data)
        switch Frame.parse(raw) {
        case .success(let frame):
            delegate?.bleDidReceive(frame: frame, event: RecordEvent(frame: frame), raw: raw)
        case .failure(let err):
            delegate?.bleDidReceiveMalformed(raw: raw, error: err)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error {
            delegate?.bleLog("subscribe failed: \(error.localizedDescription)")
        }
    }
}
