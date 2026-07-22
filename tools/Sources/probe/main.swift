import AVFoundation
import CoreAudio
import Darwin
import Foundation

// Unduck Phase-0 probe. Answers S1-S5 from docs/measurements.md.
// Every command is read-only except `devvol set`, which restores on exit.

let args = Array(CommandLine.arguments.dropFirst())

func flag(_ name: String) -> Bool { args.contains("--\(name)") }

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// When launched through LaunchServices (`open -a`) there is no stdout to read, so
// mirror everything to a file. This is the only way to run the probe as its own
// responsible process, which is what TCC attributes the audio-capture prompt to.
let logHandle: FileHandle? = {
    guard let path = option("log") else { return nil }
    FileManager.default.createFile(atPath: path, contents: nil)
    return FileHandle(forWritingAtPath: path)
}()

func print(_ message: String) {
    Swift.print(message)
    if let logHandle {
        logHandle.write(Data((message + "\n").utf8))
        try? logHandle.synchronize()
    }
}

let usage = """
Unduck probe

  list                        Audio-producing processes (S2 recon)
  watch                       Live FaceTime call detection via process objects
  tap --match <str> | --pid N [--mute] [--seconds N]
                              Tap one process, print RMS/peak dBFS each second
  s1 [--pid N | --match <str>] [--seconds N]
                              S1/S4: global tap + per-process tap side by side.
                              Start/stop a FaceTime call while this runs.
  facetime                    S2: can FaceTime.app be tapped at all?
  tone [--db -20] [--seconds N]
                              Reference sine through the default output device
  devvol [--set 0.0-1.0] [--hold N]
                              S5: read/raise output device volume, auto-restore

Info: taps require the Audio Recording TCC grant. Run from Terminal and approve
the prompt; the grant lands on Terminal, not on this binary.
"""

func resolveTargetPID() throws -> pid_t {
    if let raw = option("pid"), let pid = pid_t(raw) { return pid }
    if let match = option("match") {
        let candidates = pids(matching: match)
        guard let pid = candidates.first else { die("no process matching \(match)") }
        return pid
    }
    die("need --pid or --match")
}

func meterLoop(seconds: Int, tick: @escaping (Int) -> Void) {
    var elapsed = 0
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        elapsed += 1
        tick(elapsed)
        if seconds > 0 && elapsed >= seconds { exit(0) }
    }
    timer.resume()
    signal(SIGINT) { _ in exit(0) }
    RunLoop.main.run()
}

let seconds = Int(option("seconds") ?? "0") ?? 0

// A throw out of top-level code aborts with EXC_BREAKPOINT and a crash log rather
// than a message, which is a miserable way to learn that one API call failed.
do {
switch args.first {
case "list":
    let processes = try allAudioProcesses()
    print(String(format: "%-8s %-6s %-5s %-5s %s", ("objID" as NSString).utf8String!,
                 ("pid" as NSString).utf8String!, ("in" as NSString).utf8String!,
                 ("out" as NSString).utf8String!, ("name" as NSString).utf8String!))
    for p in processes.sorted(by: { $0.pid < $1.pid }) {
        print(String(format: "%-8d %-6d %-5@ %-5@ %@", p.objectID, p.pid,
                     p.runningInput ? "yes" : "-" as NSString,
                     p.runningOutput ? "yes" : "-" as NSString,
                     p.name as NSString))
    }

case "watch":
    let facetimePIDs = pids(matching: "/System/Applications/FaceTime.app")
    guard let ftPID = facetimePIDs.first else { die("FaceTime.app is not running — launch it first") }
    let objectID = try processObject(forPID: ftPID)
    print("watching FaceTime pid \(ftPID) (process object \(objectID)) — start/end a call")
    var lastInput = false
    var lastOutput = false
    meterLoop(seconds: seconds) { t in
        let input = readProperty(objectID, address(kAudioProcessPropertyIsRunningInput), default: UInt32(0)) != 0
        let output = readProperty(objectID, address(kAudioProcessPropertyIsRunningOutput), default: UInt32(0)) != 0
        if input != lastInput || output != lastOutput {
            print("[\(t)s] runningInput=\(input) runningOutput=\(output)  <-- CHANGE")
            lastInput = input
            lastOutput = output
        }
    }

case "tap":
    let pid = try resolveTargetPID()
    let objectID = try processObject(forPID: pid)
    let tap = try ProcessTap(label: "tap", target: .processes([objectID]), mute: flag("mute"))
    let meter = Meter()
    try tap.start { samples, frames, channels in meter.add(samples, frames: frames, channels: channels) }
    print("tapping pid \(pid) (\(NSRunningApplicationName(for: pid) ?? "?")), mute=\(flag("mute")), " +
          "format \(tap.format.mSampleRate)Hz x\(tap.format.mChannelsPerFrame)")
    meterLoop(seconds: seconds) { t in
        let m = meter.drain()
        print("[\(t)s] rms \(fmt(m.rms)) dBFS   peak \(fmt(m.peak)) dBFS   (\(m.samples) samples)")
    }

case "s1":
    let pid = try resolveTargetPID()
    let objectID = try processObject(forPID: pid)
    let globalTap = try ProcessTap(label: "global", target: .allExcept([]), mute: false)
    let procTap = try ProcessTap(label: "proc", target: .processes([objectID]), mute: false)
    let globalMeter = Meter(), procMeter = Meter()
    try globalTap.start { s, f, c in globalMeter.add(s, frames: f, channels: c) }
    try procTap.start { s, f, c in procMeter.add(s, frames: f, channels: c) }

    let device = try defaultOutputDevice()
    print("output: \(deviceName(device) ?? "?") — \(deviceOutputChannelCount(device)) output channels")
    print("target: pid \(pid) \(NSRunningApplicationName(for: pid) ?? "?")")
    print("play steady audio, then start a FaceTime call. Watch for the drop.")
    print("  t     global-rms  global-pk   proc-rms    proc-pk   devVol   devdB")
    meterLoop(seconds: seconds) { t in
        let g = globalMeter.drain(), p = procMeter.drain()
        let vol = deviceVolumeScalar(device).map { String(format: "%.2f", $0) } ?? "  n/a"
        let vdb = deviceVolumeDecibels(device).map { String(format: "%6.1f", $0) } ?? "   n/a"
        print("[\(String(format: "%3d", t))s] \(fmt(g.rms))  \(fmt(g.peak))  \(fmt(p.rms))  \(fmt(p.peak))   \(vol)  \(vdb)")
    }

case "facetime":
    let facetimePIDs = pids(matching: "/System/Applications/FaceTime.app")
    guard let ftPID = facetimePIDs.first else { die("FaceTime.app is not running — launch it first") }
    print("FaceTime pid: \(ftPID)")
    let objectID = try processObject(forPID: ftPID)
    print("process object: \(objectID)  (translate OK)")
    for mute in [false, true] {
        do {
            let tap = try ProcessTap(label: "ft", target: .processes([objectID]), mute: mute)
            let meter = Meter()
            try tap.start { s, f, c in meter.add(s, frames: f, channels: c) }
            Thread.sleep(forTimeInterval: 2)
            let m = meter.drain()
            print("  mute=\(mute): TAP OK, format \(tap.format.mSampleRate)Hz x\(tap.format.mChannelsPerFrame), " +
                  "rms \(fmt(m.rms)) dBFS over \(m.samples) samples")
            tap.invalidate()
        } catch {
            print("  mute=\(mute): TAP FAILED — \(error)")
        }
    }

case "duck":
    // One continuous run covering S1/S2/S4 plus live call detection, so nothing
    // depends on the operator hitting a stopwatch.
    //
    // The reference source is our OWN tone, not Spotify: a media app can pause
    // itself when a call starts, which is indistinguishable from the system
    // silencing it if you only watch the meter. A steady internal sine cannot pause,
    // so if its tap goes quiet the cause is the system, full stop.
    let db = Double(option("db") ?? "-20") ?? -20
    let player = TonePlayer()
    try player.start(dbfs: db, voiceProcessing: flag("vpio"))
    if flag("vpio") { print("rendering the tone through VoiceProcessingIO (S6 exemption test)") }

    let selfObject = try processObject(forPID: getpid())
    let selfTap = try ProcessTap(label: "self", target: .processes([selfObject]), mute: false)
    let globalTap = try ProcessTap(label: "global", target: .allExcept([]), mute: false)
    let selfMeter = Meter(), globalMeter = Meter()
    try selfTap.start { s, f, c in selfMeter.add(s, frames: f, channels: c) }
    try globalTap.start { s, f, c in globalMeter.add(s, frames: f, channels: c) }

    var targetObject: AudioObjectID?
    var targetMeter: Meter?
    var targetTap: ProcessTap?
    if option("pid") != nil || option("match") != nil {
        let pid = try resolveTargetPID()
        let obj = try processObject(forPID: pid)
        let meter = Meter()
        let tap = try ProcessTap(label: "target", target: .processes([obj]), mute: false)
        try tap.start { s, f, c in meter.add(s, frames: f, channels: c) }
        targetObject = obj
        targetMeter = meter
        targetTap = tap
        print("target: pid \(pid) \(NSRunningApplicationName(for: pid) ?? "?")")
    }

    // Re-resolved each tick: FaceTime may be launched after this starts, and its
    // process object is not stable across relaunches.
    func facetimeProcessObject() -> AudioObjectID? {
        pids(matching: "/System/Applications/FaceTime.app").first.flatMap { try? processObject(forPID: $0) }
    }
    let facetimeObject = facetimeProcessObject()
    let dev = try defaultOutputDevice()
    print("reference tone: \(db) dBFS sine from this process (peak \(db), rms \(db - 3.01))")
    print("output: \(deviceName(dev) ?? "?"), \(deviceOutputChannelCount(dev)) ch")
    print("FaceTime process object: \(facetimeObject.map(String.init) ?? "not running")")
    print("")
    print("Start a FaceTime call whenever you like, let it sit ~30s, then end it.")
    print("  t | tone-rms tone-pk  n | tgt-rms  tgt-pk  out | glob-rms glob-pk | vol | mic-holders")
    meterLoop(seconds: seconds) { t in
        let s = selfMeter.drain()
        let g = globalMeter.drain()
        // FaceTime.app itself never opened input during a real call — the audio is
        // owned by a daemon. So report every process holding input instead of
        // guessing which one, and let the data name the right signal to watch.
        let listeners = ((try? allAudioProcesses()) ?? [])
            .filter { $0.runningInput && $0.pid != getpid() }
            .map { ($0.bundleID?.split(separator: ".").last).map(String.init) ?? $0.name }
        let call = listeners.isEmpty ? "-" : listeners.joined(separator: ",")
        var targetColumn = "     ---     ---   -"
        if let targetMeter, let targetObject {
            let m = targetMeter.drain()
            let out = readProperty(targetObject, address(kAudioProcessPropertyIsRunningOutput), default: UInt32(0)) != 0 ? "yes" : " NO"
            targetColumn = "\(fmt(m.rms)) \(fmt(m.peak)) \(out)"
        }
        print("[\(String(format: "%3d", t))s] \(fmt(s.rms)) \(fmt(s.peak)) \(String(format: "%6d", s.samples)) | \(targetColumn) | \(fmt(g.rms)) \(fmt(g.peak)) | \(String(format: "%.2f", deviceVolumeScalar(dev) ?? 0)) | \(call)")
    }
    _ = targetTap

case "devices":
    // Looking for leaked aggregate devices: every tap creates one, and a process
    // killed with SIGKILL may not get to tear its down.
    let all = try readArrayProperty(AudioObjectID(kAudioObjectSystemObject),
                                    address(kAudioHardwarePropertyDevices), of: AudioObjectID.self)
    print("\(all.count) devices")
    for d in all {
        let ins = deviceOutputChannelCount(d)
        print("  \(String(format: "%4d", d))  \(deviceName(d) ?? "?")   uid=\(deviceUID(d) ?? "?")  outCh=\(ins)")
    }

case "micprobe":
    // Isolates whether touching the input node hangs on its own, or only when
    // voice processing is requested. The stack showed AVAudioEngine.inputNode
    // blocked in AudioDeviceCreateIOProcID on a mach_msg to coreaudiod.
    let probe = AVAudioEngine()
    print("step 1: default input device...")
    var inAddr = address(kAudioHardwarePropertyDefaultInputDevice)
    var inDev = AudioObjectID(kAudioObjectUnknown)
    var inSize = UInt32(MemoryLayout<AudioObjectID>.size)
    let inStatus = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &inAddr, 0, nil, &inSize, &inDev)
    print("  status \(inStatus), device \(inDev) \(deviceName(inDev) ?? "?") uid \(deviceUID(inDev) ?? "?")")
    print("step 2: touching engine.inputNode (this is where it hung)...")
    let node = probe.inputNode
    print("  ok — input format \(node.inputFormat(forBus: 0))")
    print("step 3: setVoiceProcessingEnabled(true)...")
    try node.setVoiceProcessingEnabled(true)
    print("  ok — voice processing enabled, format now \(node.inputFormat(forBus: 0))")

case "perm":
    print("responsible-process identity matters here — same binary, different launcher, different answer")
    for service in [audioCaptureService, microphoneService] {
        let state = tccPreflight(service).map { "\($0)" } ?? "could not preflight"
        print("  \(service): \(state)")
    }
    if flag("request") {
        for service in [audioCaptureService, microphoneService] {
            let result = tccRequest(service).map { $0 ? "granted" : "refused" } ?? "timed out / no answer"
            print("  requested \(service) -> \(result)")
            print("  now: \(tccPreflight(service).map { "\($0)" } ?? "?")")
        }
    }

case "selftest":
    // Ground truth with no external app involved: this process plays a known tone
    // and taps both itself and the global mix. If these read -inf, the tap path is
    // broken (or denied); if they read ~the tone level, taps work and any silence
    // seen elsewhere is the target app's, not ours.
    let db = Double(option("db") ?? "-20") ?? -20
    let player = TonePlayer()
    try player.start(dbfs: db)
    let selfObject = try processObject(forPID: getpid())
    let globalTap = try ProcessTap(label: "global", target: .allExcept([]), mute: false)
    let selfTap = try ProcessTap(label: "self", target: .processes([selfObject]), mute: false)
    let globalMeter = Meter(), selfMeter = Meter()
    try globalTap.start { s, f, c in globalMeter.add(s, frames: f, channels: c) }
    try selfTap.start { s, f, c in selfMeter.add(s, frames: f, channels: c) }
    let dev = try defaultOutputDevice()
    print("playing \(db) dBFS sine from pid \(getpid()) (process object \(selfObject))")
    print("output: \(deviceName(dev) ?? "?"), \(deviceOutputChannelCount(dev)) ch, vol \(deviceVolumeScalar(dev).map { String($0) } ?? "n/a")")
    print("expect both meters near \(db) dBFS if taps are working")
    meterLoop(seconds: seconds) { t in
        let g = globalMeter.drain(), s = selfMeter.drain()
        print("[\(t)s] global rms \(fmt(g.rms))  peak \(fmt(g.peak))   |   self rms \(fmt(s.rms))  peak \(fmt(s.peak))")
    }

case "tone":
    let db = Double(option("db") ?? "-20") ?? -20
    let player = TonePlayer()
    print("starting tone engine (vpio=\(flag("vpio")))...")
    try player.start(dbfs: db, voiceProcessing: flag("vpio"))
    print("playing \(db) dBFS sine (pid \(getpid())) — tap this pid from another terminal")
    meterLoop(seconds: seconds) { _ in }

case "devvol":
    let device = try defaultOutputDevice()
    let name = deviceName(device) ?? "?"
    let original = deviceVolumeScalar(device)
    print("device: \(name)  uid \(deviceUID(device) ?? "?")  outCh \(deviceOutputChannelCount(device))")
    print("volume scalar: \(original.map { String($0) } ?? "n/a")   dB: \(deviceVolumeDecibels(device).map { String($0) } ?? "n/a")")
    if let raw = option("set"), let target = Float32(raw) {
        guard let original else { die("device has no settable volume") }
        try setDeviceVolumeScalar(device, target)
        print("set -> \(deviceVolumeScalar(device).map { String($0) } ?? "?")  dB \(deviceVolumeDecibels(device).map { String($0) } ?? "n/a")")
        let hold = Int(option("hold") ?? "10") ?? 10
        print("holding \(hold)s, then restoring \(original)")
        Thread.sleep(forTimeInterval: TimeInterval(hold))
        try setDeviceVolumeScalar(device, original)
        print("restored")
    }

default:
    print(usage)
}
} catch {
    print("ERROR: \(error)")
    exit(1)
}
