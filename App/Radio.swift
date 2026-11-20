import Foundation
import CoreBluetooth
import UIKit
import WebKit

/// Connectionless Bluetooth "radio" with two channels on one band.
/// Every phone advertises a tiny BLE packet and scans for everyone else's. Nobody connects to anybody,
/// so any number of phones in range (roughly 10–30 m) hear every transmitter. No internet, no network.
///
/// Packet = one 128-bit service UUID: 2-byte magic + 14 payload bytes, plus the call sign as local name.
///   "MT" Morse channel: payload built by the web layer (key timings + decoded letters)
///   "MV" Voice channel: payload built by VoiceEngine (Codec2 700C, 120 ms of speech)
/// A phone listens to one channel at a time and ignores the other channel's packets,
/// so Morse and voice never mix. Activity on the other channel is reported so nobody misses it.
final class RadioManager: NSObject {
    static let morseMagic: [UInt8] = [0x4D, 0x54] // "MT"
    static let voiceMagic: [UInt8] = [0x4D, 0x56] // "MV"

    weak var webView: WKWebView?
    private var peripheral: CBPeripheralManager?
    private var central: CBCentralManager?
    private var on = false
    private var mode = "morse"
    private var talking = false
    private var name = ""
    private var morsePayload = Data(count: 14)
    private var lastSeen: [UUID: Data] = [:]
    private var otherNotified: [String: Date] = [:]
    private var newPackets = 0
    private var rateTimer: Timer?
    private let voice = VoiceEngine()

    override init() {
        super.init()
        voice.onPacket = { [weak self] data in self?.advertise(Self.voiceMagic, data) }
        voice.onTalker = { [weak self] who, isOn in self?.emit(["type": "talker", "name": who, "on": isOn]) }
    }

    func handle(_ body: Any) {
        guard let dict = body as? [String: Any], let cmd = dict["cmd"] as? String else { return }
        switch cmd {
        case "start":
            name = String((dict["name"] as? String ?? "MORSE").prefix(8))
            if let m = dict["mode"] as? String { mode = m }
            start()
        case "stop":
            stop()
        case "mode":
            mode = (dict["mode"] as? String) == "voice" ? "voice" : "morse"
            lastSeen = [:]
            if mode == "morse" { endTalk(); voice.stopListening(); advertiseMorse() }
            else { peripheral?.stopAdvertising(); if on { voice.startListening() } }
            report()
        case "adv":
            if let hex = dict["hex"] as? String, let data = Data(hex: hex) {
                morsePayload = data.count >= 14 ? Data(data.prefix(14)) : data + Data(count: 14 - data.count)
                advertiseMorse()
            }
        case "ptt":
            if (dict["down"] as? Bool) == true { beginTalk() } else { endTalk() }
        default: break
        }
    }

    private func start() {
        on = true
        lastSeen = [:]
        if peripheral == nil { peripheral = CBPeripheralManager(delegate: self, queue: nil) } else { advertiseMorse() }
        if central == nil { central = CBCentralManager(delegate: self, queue: nil) } else { scan() }
        if mode == "voice" { voice.startListening() }
        rateTimer?.invalidate()
        rateTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.emit(["type": "rate", "pps": Double(self.newPackets) / 2])
            self.newPackets = 0
        }
        report()
    }

    private func stop() {
        on = false
        endTalk()
        voice.stopListening()
        peripheral?.stopAdvertising()
        central?.stopScan()
        rateTimer?.invalidate(); rateTimer = nil
        report()
    }

    private func beginTalk() {
        guard on, mode == "voice", !talking else { return }
        talking = true
        voice.startTalking { [weak self] in
            self?.talking = false
            self?.emit(["type": "error", "code": "mic"])
        }
    }

    private func endTalk() {
        guard talking else { return }
        talking = false
        voice.stopTalking()
        // let the last packet linger briefly so listeners catch it, then go quiet
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.talking, self.mode == "voice" else { return }
            self.peripheral?.stopAdvertising()
        }
    }

    private func advertiseMorse() {
        guard mode == "morse" else { return }
        advertise(Self.morseMagic, morsePayload)
    }

    private func advertise(_ magic: [UInt8], _ payload: Data) {
        guard on, let peripheral, peripheral.state == .poweredOn else { return }
        var bytes = Data(magic)
        bytes.append(payload)
        peripheral.stopAdvertising()
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(data: bytes)],
            CBAdvertisementDataLocalNameKey: name
        ])
    }

    private func scan() {
        guard on, let central, central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    private func stateName(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOn: return "on"
        case .poweredOff: return "off"
        case .unauthorized: return "unauthorized"
        case .unsupported: return "unsupported"
        default: return "starting"
        }
    }

    private func report() {
        emit(["type": "state", "on": on, "bt": stateName(central?.state ?? .unknown), "mode": mode])
    }

    private func emit(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("window.radioEvent && window.radioEvent(\(json))", completionHandler: nil)
        }
    }

    private func noteOther(_ kind: String, _ who: String) {
        let key = kind + who
        if let last = otherNotified[key], Date().timeIntervalSince(last) < 3 { return }
        otherNotified[key] = Date()
        emit(["type": "other", "kind": kind, "name": who])
    }
}

extension RadioManager: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        advertiseMorse()
        report()
    }
}

extension RadioManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        scan()
        report()
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard on else { return }
        let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        for u in uuids {
            let d = [UInt8](u.data)
            guard d.count == 16, d[0] == 0x4D, d[1] == 0x54 || d[1] == 0x56 else { continue }
            let isVoice = d[1] == 0x56
            let body = Data(d[2...])
            if lastSeen[p.identifier] == body { return } // same packet heard again
            lastSeen[p.identifier] = body
            newPackets += 1
            let sender = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? p.name ?? ""
            if isVoice {
                if mode == "voice" { voice.receive(body, from: sender, key: p.identifier.uuidString) }
                else { noteOther("voice", sender) }
            } else {
                if mode == "morse" { emit(["type": "bc", "hex": body.hexString, "name": sender, "rssi": RSSI.intValue]) }
                else if body[body.startIndex + 4] != 62 || body[body.startIndex + 3] > 1 { noteOther("morse", sender) }
            }
            return
        }
    }
}

private extension Data {
    init?(hex: String) {
        var data = Data()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            data.append(b)
            idx = next
        }
        self = data
    }
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
