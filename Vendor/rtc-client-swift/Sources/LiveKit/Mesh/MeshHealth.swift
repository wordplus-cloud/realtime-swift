/*
 * Copyright 2026 The WordPlus RTC client authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import AVFoundation
import Foundation

#if canImport(Metal)
import Metal
#endif

#if os(iOS) || os(visionOS) || os(tvOS)
import UIKit
#endif

// WordPlus Mesh (1.0.7, as rtc-client 1.0.16's room/meshHealth.ts): how the device and the app running a call are
// doing, told to the node with the other reports (`MeshHealth.field`), numbers and the device's names only. A call where
// a viewer's playback froze on every camera at once and its own camera stopped arriving, on a clean line
// (2026-10-23), was a machine that hung; nothing the node saw could say so.
//
// Nothing here runs a timer of its own, so collecting it adds no load to the device: the system's thermal state (`ProcessInfo.thermalState`, the device's own measure of how hard it is
// pushed, named as the browser's CPU pressure is: nominal, fair, serious, critical), the app going to the background and
// back, the battery charging or not, audio routes and cameras plugged in or out: each a notification the system posts
// anyway, which adds to a counter. The path each connection runs on comes from the connections' shared reading
// (MeshStats). The browser's main-thread hangs have no native counterpart that costs nothing (a watchdog is a timer),
// so a device says none.

enum MeshHealth {
    /// The signal request field the report goes in (WordPlus Mesh 1.0.53's `MeshHealthFieldNumber`).
    static let field: UInt64 = 1003

    /// One connection's path as libwebrtc sees it now, and since the last reading: the round trip (ms) and the upload
    /// it estimates (kbit/s), packets the system failed to send (a network gone away), connectivity checks unanswered,
    /// the times it changed path.
    struct Path: Codable, Equatable {
        var rtt: Int?
        var outKbps: Int?
        var sendFailed: Int?
        var unanswered: Int?
        var switched: Int?
    }

    /// The device, once a connection: its cores, memory (GB) and graphics.
    struct Machine: Codable, Equatable {
        var cores: Int?
        var memGb: Double?
        var gpu: String?
    }

    /// The device and the app since the last reading, as the node reads it (its `MeshHealth`): only what there is to say.
    struct Report: Codable, Equatable {
        var cpu: String?
        var cpuMs: Int?
        var hangs: Int?
        var hangMs: Int?
        var hiddenMs: Int?
        var battery: Bool?
        var devices: Int?
        var pub: Path?
        var sub: Path?
        var machine: Machine?

        var isEmpty: Bool { self == Report() }
    }

    /// A connection's path totals at a reading, for what changed since.
    struct PathTotals: Equatable {
        var sendFailed: Double?
        var asked: Double?
        var answered: Double?
        var switched: Double?
    }

    static let pressureRank = ["nominal": 0, "fair": 1, "serious": 2, "critical": 3]

    /// The system's thermal state named as the node reads pressure.
    static func pressure(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "nominal"
        }
    }

    /// A connection's path from its reading: the selected pair's round trip and upload estimate, and what changed since
    /// `before` (its totals at the last reading); nil where the reading has no selected pair.
    static func path(_ stats: [MeshEncoders.Stat], before: PathTotals?) -> (path: Path, totals: PathTotals)? {
        func num(_ v: Any?) -> Double? {
            guard let d = (v as? NSNumber)?.doubleValue, d.isFinite else { return nil }
            return d
        }
        guard let transport = stats.first(where: { $0.type == "transport" && $0.values["selectedCandidatePairId"] is String }),
              let pairId = transport.values["selectedCandidatePairId"] as? String,
              let pair = stats.first(where: { $0.id == pairId }) else { return nil }
        let now = PathTotals(sendFailed: num(pair.values["packetsDiscardedOnSend"]),
                             asked: num(pair.values["consentRequestsSent"]) ?? num(pair.values["requestsSent"]),
                             answered: num(pair.values["responsesReceived"]),
                             switched: num(transport.values["selectedCandidatePairChanges"]))
        func delta(_ a: Double?, _ b: Double?) -> Double? {
            guard let a, let b, b >= a else { return nil }
            return b - a
        }
        var out = Path()
        if let rtt = num(pair.values["currentRoundTripTime"]) { out.rtt = Int((rtt * 1000).rounded()) }
        if let bps = num(pair.values["availableOutgoingBitrate"]) { out.outKbps = Int((bps / 1000).rounded()) }
        if let before {
            if let failed = delta(before.sendFailed, now.sendFailed), failed > 0 { out.sendFailed = Int(failed) }
            if let asked = delta(before.asked, now.asked), let answered = delta(before.answered, now.answered), asked > answered {
                out.unanswered = Int(asked - answered)
            }
            if let switched = delta(before.switched, now.switched), switched > 0 { out.switched = Int(switched) }
        }
        return (out, now)
    }

    /// The report as a node reads it, its keys sorted.
    static func json(_ report: Report) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(report)
    }

    /// The device: its cores, its memory, and its graphics as Metal names them ("Apple A17 Pro GPU"), the device's model
    /// being in its join already (ClientInfo).
    static let machine: Machine? = {
        let info = ProcessInfo.processInfo
        var out = Machine(cores: info.activeProcessorCount,
                          memGb: (Double(info.physicalMemory) / 1_073_741_824 * 10).rounded() / 10)
        #if canImport(Metal)
        if let name = MTLCreateSystemDefaultDevice()?.name, !name.isEmpty {
            out.gpu = String(name.prefix(60))
        }
        #endif
        return out
    }()
}

/// Counts what happens to the device and the app between two readings, from the system's own notifications.
final class MeshHealthWatch: @unchecked Sendable {
    private struct Counters {
        /// the worst thermal state since the last reading, the one it is in, since when, and ms serious or worse
        var cpu: String?
        var pressure: String?
        var pressureAt = Date()
        var cpuMs = 0.0
        var hiddenMs = 0.0
        var hiddenAt: Date?
        var devices = 0
    }

    private struct State {
        var counters = Counters()
        var battery: Bool?
        var paths: [String: MeshHealth.PathTotals] = [:]
        var machineSaid = false
        var observers: [NSObjectProtocol] = []
        var started = false
        #if os(iOS) || os(visionOS)
        var monitoringBattery = false
        #endif
    }

    private let _state = StateSync(State())

    /// Starts counting, from the state the system is in now.
    func start() {
        let first = _state.mutate { state -> Bool in
            guard !state.started else { return false }
            state.started = true
            state.counters = Counters()
            return true
        }
        guard first else { return }
        pressureChanged(MeshHealth.pressure(ProcessInfo.processInfo.thermalState))

        let center = NotificationCenter.default
        var observers: [NSObjectProtocol] = []
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.pressureChanged(MeshHealth.pressure(ProcessInfo.processInfo.thermalState))
        })
        #if os(iOS) || os(visionOS) || os(tvOS)
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.visibilityChanged(hidden: true)
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.visibilityChanged(hidden: false)
        })
        #endif
        #if os(iOS) || os(visionOS) || os(tvOS)
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            if reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue ||
                reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            {
                self?.deviceChanged()
            }
        })
        #endif
        #if os(iOS) || os(macOS)
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.deviceChanged()
            })
        }
        #endif
        #if os(iOS) || os(visionOS)
        observers.append(center.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.readBattery() }
        })
        #endif
        _state.mutate { $0.observers = observers }

        // what the app is in at the start: the background (a call answered on the lock screen) or not, the battery
        Task { @MainActor [weak self] in
            #if os(iOS) || os(visionOS)
            let device = UIDevice.current
            if !device.isBatteryMonitoringEnabled {
                device.isBatteryMonitoringEnabled = true
                self?._state.mutate { $0.monitoringBattery = true }
            }
            self?.readBattery()
            #endif
            #if os(iOS) || os(visionOS) || os(tvOS)
            if let background = Self.inBackground() {
                self?.visibilityChanged(hidden: background)
            }
            #endif
        }
    }

    func stop() {
        let observers = _state.mutate { state -> [NSObjectProtocol] in
            let observers = state.observers
            state.observers = []
            state.started = false
            return observers
        }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        #if os(iOS) || os(visionOS)
        if _state.mutate({ state -> Bool in
            defer { state.monitoringBattery = false }
            return state.monitoringBattery
        }) {
            Task { @MainActor in UIDevice.current.isBatteryMonitoringEnabled = false }
        }
        #endif
    }

    /// The next reading tells the device again: after a join or a reconnect, to a node that may know nothing of it.
    func tellMachineAgain() {
        _state.mutate { $0.machineSaid = false }
    }

    func pressureChanged(_ state: String, now: Date = Date()) {
        guard let rank = MeshHealth.pressureRank[state] else { return }
        _state.mutate {
            Self.accountPressure(&$0.counters, now: now)
            $0.counters.pressure = state
            if $0.counters.cpu.flatMap({ MeshHealth.pressureRank[$0] }).map({ rank > $0 }) ?? true {
                $0.counters.cpu = state
            }
        }
    }

    private static func accountPressure(_ c: inout Counters, now: Date) {
        if let p = c.pressure, let rank = MeshHealth.pressureRank[p], rank >= 2 {
            c.cpuMs += now.timeIntervalSince(c.pressureAt) * 1000
        }
        c.pressureAt = now
    }

    func visibilityChanged(hidden: Bool, now: Date = Date()) {
        _state.mutate {
            if hidden, $0.counters.hiddenAt == nil {
                $0.counters.hiddenAt = now
            } else if !hidden, let at = $0.counters.hiddenAt {
                $0.counters.hiddenMs += now.timeIntervalSince(at) * 1000
                $0.counters.hiddenAt = nil
            }
        }
    }

    func deviceChanged() {
        _state.mutate { $0.counters.devices += 1 }
    }

    func batteryChanged(onBattery: Bool?) {
        _state.mutate { $0.battery = onBattery }
    }

    /// Whether something since the last reading can't wait for the next: a thermal state serious or worse, a device
    /// plugged in or out.
    func troubled() -> Bool {
        _state.read {
            ($0.counters.cpu.flatMap { MeshHealth.pressureRank[$0] } ?? 0) >= 2 || $0.counters.devices > 0
        }
    }

    /// What happened since the last reading, and the counters started over; paths: each connection's shared reading by
    /// name ("pub", "sub"). Only what there is to say: a quiet app on a cool device says almost nothing.
    func reading(paths: [String: [MeshEncoders.Stat]], now: Date = Date()) -> MeshHealth.Report {
        _state.mutate { state in
            Self.accountPressure(&state.counters, now: now)
            let c = state.counters
            var out = MeshHealth.Report()
            if let cpu = c.cpu, cpu != "nominal" { out.cpu = cpu }
            if c.cpuMs > 0 { out.cpuMs = Int(c.cpuMs.rounded()) }
            let hiddenMs = c.hiddenMs + (c.hiddenAt.map { now.timeIntervalSince($0) * 1000 } ?? 0)
            if hiddenMs > 0 { out.hiddenMs = Int(hiddenMs.rounded()) }
            out.battery = state.battery
            if c.devices > 0 { out.devices = c.devices }
            for (name, stats) in paths where name == "pub" || name == "sub" {
                guard let read = MeshHealth.path(stats, before: state.paths[name]) else { continue }
                state.paths[name] = read.totals
                if name == "pub" { out.pub = read.path } else { out.sub = read.path }
            }
            if !state.machineSaid {
                out.machine = MeshHealth.machine
                state.machineSaid = true
            }
            // what carries on (a thermal state, the background) starts the next reading as it is now
            state.counters = Counters(cpu: c.pressure, pressure: c.pressure, pressureAt: now, hiddenAt: c.hiddenAt != nil ? now : nil)
            return out
        }
    }

    #if os(iOS) || os(visionOS)
    @MainActor
    private func readBattery() {
        switch UIDevice.current.batteryState {
        case .unplugged: batteryChanged(onBattery: true)
        case .charging, .full: batteryChanged(onBattery: false)
        default: batteryChanged(onBattery: nil)
        }
    }
    #endif

    #if os(iOS) || os(visionOS) || os(tvOS)
    /// Whether the app is in the background now; nil in an app extension, which has no application to ask. Resolved
    /// through the Objective-C runtime, as `LiveKit+DeviceHelpers` does, since `UIApplication.shared` doesn't compile
    /// for extensions.
    @MainActor
    private static func inBackground() -> Bool? {
        guard Bundle.main.bundleURL.pathExtension != "appex" else { return nil }
        let selector = NSSelectorFromString("sharedApplication")
        guard UIApplication.responds(to: selector),
              let shared = UIApplication.perform(selector),
              let application = shared.takeUnretainedValue() as? UIApplication else { return nil }
        return application.applicationState == .background
    }
    #endif
}
