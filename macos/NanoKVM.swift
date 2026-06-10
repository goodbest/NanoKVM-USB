import AppKit
import AudioToolbox
import AVFoundation
import CoreMedia
import CoreImage
import VideoToolbox
import UniformTypeIdentifiers

struct DisplayColor {
    var brightness: Double
    var contrast: Double
    var saturation: Double

    static let recommended = DisplayColor(brightness: 1.01, contrast: 1.12, saturation: 1.09)
    static let neutral = DisplayColor(brightness: 1.00, contrast: 1.00, saturation: 1.00)
    static let rangeExpand = DisplayColor(brightness: 1.00, contrast: 1.15, saturation: 1.08)
}

enum VideoFrameRateChoice: String, CaseIterable {
    case auto, fps60, fps50, fps30, fps25

    init(rawValue: String) {
        switch rawValue {
        case "60": self = .fps60
        case "50": self = .fps50
        case "30": self = .fps30
        case "25": self = .fps25
        default: self = .auto
        }
    }

    var storageValue: String {
        switch self {
        case .auto: return "auto"
        case .fps60: return "60"
        case .fps50: return "50"
        case .fps30: return "30"
        case .fps25: return "25"
        }
    }

    var fps: Double? {
        switch self {
        case .auto: return nil
        case .fps60: return 60
        case .fps50: return 50
        case .fps30: return 30
        case .fps25: return 25
        }
    }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .fps60: return "60 fps"
        case .fps50: return "50 fps"
        case .fps30: return "30 fps"
        case .fps25: return "25 fps"
        }
    }
}

struct SerialMetrics {
    var writeCount: Int = 0
    var errorCount: Int = 0
    var lastWriteMs: Double = 0
    var averageWriteMs: Double = 0
    var maxWriteMs: Double = 0
    var lastError: String = ""
    var lastWriteAt: Date?
}

struct NanoKVMInfo {
    let chipVersion: String
    let isConnected: Bool
    let numLock: Bool
    let capsLock: Bool
    let scrollLock: Bool
}

struct Config {
    static let windowWidth:  CGFloat = 1280
    static let windowHeight: CGFloat = 720
    static var scrollDirection = -1
    static var scrollSpeed: Double = 0.01
    static let flushInterval = 1.0 / 30.0
    static var mouseAbsolute = true
    static var cursorHiddenPreferred = true
    static var keyboardCaptureHostShortcuts = true
    static let backgroundRefreshAdaptive: TimeInterval = -2
    static let backgroundRefreshPaused: TimeInterval = -1
    static let backgroundRefreshLive: TimeInterval = 0
    static let backgroundRefreshDefault: TimeInterval = backgroundRefreshAdaptive
    static let backgroundStatusThreshold: TimeInterval = 5
    static let backgroundRefreshPolicyVersion = 5
    static let adaptiveRefreshFast: TimeInterval = 5
    static let adaptiveRefreshMedium: TimeInterval = 30
    static let adaptiveRefreshSlow: TimeInterval = 60
    static let adaptiveRefreshMediumAfter: TimeInterval = 15 * 60
    static let adaptiveRefreshSlowAfter: TimeInterval = 60 * 60
    static let videoFormatPolicyVersion = 1
    static let preferredDefaultVideoW = 1920
    static let preferredDefaultVideoH = 1080
    static let inactivePauseGrace: TimeInterval = 3.0
    static let foregroundResumeRevealDelay: TimeInterval = 0.45
    static let foregroundResumeFramesRequired = 3
}

final class AudioRingBuffer {
    private var buf: [Float32]
    private let cap: Int
    private let mask: Int
    private var ri = 0, wi = 0, n = 0
    private var lock = os_unfair_lock()

    init(capacity: Int) {
        assert(capacity > 0 && capacity & (capacity - 1) == 0, "capacity must be power of 2")
        cap = capacity
        mask = capacity - 1
        buf = [Float32](repeating: 0, count: capacity)
    }

    func write(_ src: UnsafePointer<Float32>, count: Int) {
        os_unfair_lock_lock(&lock)
        buf.withUnsafeMutableBufferPointer { bp in
            let first = min(count, cap - wi)
            memcpy(bp.baseAddress! + wi, src, first * MemoryLayout<Float32>.stride)
            if first < count {
                memcpy(bp.baseAddress!, src + first, (count - first) * MemoryLayout<Float32>.stride)
            }
        }
        wi = (wi + count) & mask
        let overflow = (n + count) - cap
        if overflow > 0 { ri = (ri + overflow) & mask }
        n = min(cap, n + count)
        os_unfair_lock_unlock(&lock)
    }

    func read(_ dst: UnsafeMutablePointer<Float32>, count: Int) {
        os_unfair_lock_lock(&lock)
        if n < count {
            memset(dst, 0, count * MemoryLayout<Float32>.size)
        } else {
            buf.withUnsafeMutableBufferPointer { bp in
                let first = min(count, cap - ri)
                memcpy(dst, bp.baseAddress! + ri, first * MemoryLayout<Float32>.stride)
                if first < count {
                    memcpy(dst + first, bp.baseAddress!, (count - first) * MemoryLayout<Float32>.stride)
                }
            }
            ri = (ri + count) & mask
            n -= count
        }
        os_unfair_lock_unlock(&lock)
    }

    func drain() {
        os_unfair_lock_lock(&lock)
        ri = 0; wi = 0; n = 0
        os_unfair_lock_unlock(&lock)
    }
}

class SerialPort {
    private var fd: Int32 = -1
    private let writeQueue = DispatchQueue(label: "com.nanokvm.serial", qos: .userInitiated)
    private var sendBuf = [UInt8](repeating: 0, count: 32)
    private var stats = SerialMetrics()
    var isOpen: Bool { fd >= 0 }
    func open(path: String) -> Bool {
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        var tty = termios()
        tcgetattr(fd, &tty)
        cfsetispeed(&tty, speed_t(B57600))
        cfsetospeed(&tty, speed_t(B57600))
        cfmakeraw(&tty)
        tty.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)
        tty.c_cflag &= ~tcflag_t(PARENB | CSTOPB)
        withUnsafeMutablePointer(to: &tty.c_cc) {
            let p = UnsafeMutableRawPointer($0).assumingMemoryBound(to: cc_t.self)
            p[Int(VMIN)] = 0; p[Int(VTIME)] = 5
        }
        tcsetattr(fd, TCSANOW, &tty)
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        // Drain any pending data instead of blocking sleep
        var drain = [UInt8](repeating: 0, count: 64)
        _ = Darwin.read(fd, &drain, drain.count)
        return true
    }
    func close() {
        writeQueue.sync {
            guard fd >= 0 else { return }
            Darwin.close(fd); fd = -1
        }
    }
    func metrics() -> SerialMetrics {
        writeQueue.sync { stats }
    }
    private func recordWrite(_ written: Int, durationMs: Double) {
        stats.writeCount += 1
        stats.lastWriteMs = durationMs
        stats.maxWriteMs = max(stats.maxWriteMs, durationMs)
        stats.averageWriteMs =
            (stats.averageWriteMs * Double(stats.writeCount - 1) + durationMs) /
            Double(stats.writeCount)
        stats.lastWriteAt = Date()
        if written < 0 {
            stats.errorCount += 1
            stats.lastError = String(cString: strerror(errno))
        }
    }
    private func send(cmd: UInt8, data: [UInt8]) {
        guard fd >= 0, data.count <= 26 else { return }
        writeQueue.async { [self] in
            guard self.fd >= 0 else { return }
            let n = data.count
            let len = 6 + n
            sendBuf[0]=0x57;sendBuf[1]=0xAB;sendBuf[2]=0x00;sendBuf[3]=cmd;sendBuf[4]=UInt8(n)
            for i in 0..<n { sendBuf[5+i] = data[i] }
            var s: UInt32 = 0
            for i in 0..<(5+n) { s += UInt32(sendBuf[i]) }
            sendBuf[5+n] = UInt8(s & 0xFF)
            let started = DispatchTime.now().uptimeNanoseconds
            let written = sendBuf.withUnsafeBufferPointer {
                Darwin.write(self.fd, $0.baseAddress!, len)
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000.0
            recordWrite(written, durationMs: elapsed)
            if written < 0 {
                Darwin.close(self.fd); self.fd = -1
                DispatchQueue.main.async { print("Serial: device disconnected") }
            }
        }
    }
    func sendKeyboard(_ r: [UInt8]) { send(cmd: 0x02, data: r) }
    func sendMouseAbsolute(_ r: [UInt8]) { send(cmd: 0x04, data: r) }
    func sendMouseRelative(_ r: [UInt8]) { send(cmd: 0x05, data: r) }
    func getInfo(completion: @escaping ([UInt8]?) -> Void) {
        writeQueue.async { [self] in
            guard fd >= 0 else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var b = [UInt8](repeating: 0, count: 32)
            b[0]=0x57;b[1]=0xAB;b[2]=0x00;b[3]=0x01;b[4]=0x01;b[5]=0x00
            var s: UInt32 = 0
            for i in 0..<6 { s += UInt32(b[i]) }
            b[6] = UInt8(s & 0xFF)
            let started = DispatchTime.now().uptimeNanoseconds
            let written = b.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress!, 7) }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000.0
            recordWrite(written, durationMs: elapsed)
            var resp = [UInt8](repeating: 0, count: 16)
            let count = Darwin.read(fd, &resp, resp.count)
            let result = count > 0 ? Array(resp.prefix(count)) : nil
            DispatchQueue.main.async { completion(result) }
        }
    }
}

class KeyboardHID {
    private var mods: UInt8 = 0
    private var keys = [UInt8]()
    private var buf: [UInt8] = [0,0,0,0,0,0,0,0]
    func keyDown(_ h: UInt8) -> [UInt8] {
        if let m = modBit(h) { mods |= m }
        else if !keys.contains(h) && keys.count < 6 { keys.append(h) }
        return report()
    }
    func keyUp(_ h: UInt8) -> [UInt8] {
        if let m = modBit(h) { mods &= ~m }
        else { keys.removeAll { $0 == h } }
        return report()
    }
    func releaseAll() -> [UInt8] { mods = 0; keys.removeAll(); return report() }
    private func report() -> [UInt8] {
        buf[0] = mods; buf[1] = 0
        for i in 0..<6 { buf[2+i] = i < keys.count ? keys[i] : 0 }
        return buf
    }
    private func modBit(_ h: UInt8) -> UInt8? {
        switch h {
        case 0xE0: return 0x01; case 0xE1: return 0x02
        case 0xE2: return 0x04; case 0xE3: return 0x08
        case 0xE4: return 0x10; case 0xE5: return 0x20
        case 0xE6: return 0x40; case 0xE7: return 0x80
        default: return nil
        }
    }
}

class MouseHID {
    var buttons: UInt8 = 0
    private var absReport: [UInt8] = [0x02, 0, 0, 0, 0, 0, 0]
    private var relReport: [UInt8] = [0x01, 0, 0, 0, 0]
    func buttonDown(_ b: Int) { buttons |= bit(b) }
    func buttonUp(_ b: Int) { buttons &= ~bit(b) }
    func isButtonDown(_ b: Int) -> Bool { buttons & bit(b) != 0 }
    var hasButtonsDown: Bool { buttons != 0 }
    func releaseButtons() { buttons = 0 }
    func build(nx: Double, ny: Double, scroll: Int = 0) -> [UInt8] {
        let x = UInt16(clamping: Int(max(0,min(1,nx))*4095))
        let y = UInt16(clamping: Int(max(0,min(1,ny))*4095))
        absReport[1] = buttons
        absReport[2] = UInt8(x&0xFF); absReport[3] = UInt8(x>>8)
        absReport[4] = UInt8(y&0xFF); absReport[5] = UInt8(y>>8)
        absReport[6] = UInt8(bitPattern: Int8(clamping: max(-127,min(127,scroll))))
        return absReport
    }
    func buildRelative(dx: Int, dy: Int, scroll: Int = 0) -> [UInt8] {
        relReport[1] = buttons
        relReport[2] = UInt8(bitPattern: Int8(clamping: dx))
        relReport[3] = UInt8(bitPattern: Int8(clamping: dy))
        relReport[4] = UInt8(bitPattern: Int8(clamping: scroll))
        return relReport
    }
    func reset() -> [UInt8] { buttons = 0; return build(nx:0,ny:0) }
    private func bit(_ b: Int) -> UInt8 {
        switch b {
        case 0: return 0x01; case 1: return 0x02; case 2: return 0x04
        case 3: return 0x08; case 4: return 0x10; default: return 0
        }
    }
}

// macOS virtual keycode → USB HID usage ID (flat array, index = keycode)
// Keycodes verified against Carbon/HIToolbox kVK constants
let macToHID: [UInt8] = {
    var t = [UInt8](repeating: 0, count: 128)
    // Letters – left hand
    t[0x00]=0x04; t[0x01]=0x16; t[0x02]=0x07; t[0x03]=0x09; t[0x04]=0x0B // a s d f h
    t[0x05]=0x0A; t[0x06]=0x1D; t[0x07]=0x1B; t[0x08]=0x06; t[0x09]=0x19 // g z x c v
    t[0x0B]=0x05; t[0x0C]=0x14; t[0x0D]=0x1A; t[0x0E]=0x08; t[0x0F]=0x15 // b q w e r
    t[0x10]=0x1C; t[0x11]=0x17                                             // y t
    // Letters – right hand
    t[0x20]=0x18; t[0x22]=0x0C; t[0x1F]=0x12; t[0x23]=0x13               // u i o p
    t[0x26]=0x0D; t[0x28]=0x0E; t[0x25]=0x0F                               // j k l
    t[0x2D]=0x11; t[0x2E]=0x10                                             // n m
    // Numbers
    t[0x12]=0x1E; t[0x13]=0x1F; t[0x14]=0x20; t[0x15]=0x21               // 1 2 3 4
    t[0x17]=0x22; t[0x16]=0x23                                             // 5 6
    t[0x1A]=0x24; t[0x1C]=0x25; t[0x19]=0x26; t[0x1D]=0x27               // 7 8 9 0
    // Punctuation
    t[0x1B]=0x2D; t[0x18]=0x2E                                             // - =
    t[0x21]=0x2F; t[0x1E]=0x30; t[0x2A]=0x31                               // [ ] backslash
    t[0x29]=0x33; t[0x27]=0x34; t[0x32]=0x35                               // ; ' `
    t[0x2B]=0x36; t[0x2F]=0x37; t[0x2C]=0x38                               // , . /
    // Special keys
    t[0x24]=0x28; t[0x30]=0x2B; t[0x31]=0x2C; t[0x33]=0x2A               // Return Tab Space Backspace
    t[0x35]=0x29; t[0x39]=0x39                                             // Escape CapsLock
    // Modifiers
    t[0x37]=0xE3; t[0x36]=0xE7; t[0x38]=0xE1; t[0x3C]=0xE5               // LCmd RCmd LShift RShift
    t[0x3A]=0xE2; t[0x3D]=0xE6; t[0x3B]=0xE0; t[0x3E]=0xE4               // LOpt ROpt LCtrl RCtrl
    // Function keys
    t[0x7A]=0x3A; t[0x78]=0x3B; t[0x63]=0x3C; t[0x76]=0x3D               // F1-F4
    t[0x60]=0x3E; t[0x61]=0x3F; t[0x62]=0x40; t[0x64]=0x41               // F5-F8
    t[0x65]=0x42; t[0x6D]=0x43; t[0x67]=0x44; t[0x6F]=0x45               // F9-F12
    // Navigation
    t[0x72]=0x49; t[0x73]=0x4A; t[0x74]=0x4B; t[0x75]=0x4C               // Insert Home PgUp FwdDel
    t[0x77]=0x4D; t[0x79]=0x4E                                             // End PgDn
    // Arrow keys
    t[0x7B]=0x50; t[0x7C]=0x4F; t[0x7D]=0x51; t[0x7E]=0x52               // ← → ↓ ↑
    // Keypad
    t[0x52]=0x62; t[0x53]=0x59; t[0x54]=0x5A; t[0x55]=0x5B               // KP 0 1 2 3
    t[0x56]=0x5C; t[0x57]=0x5D; t[0x58]=0x5E; t[0x59]=0x5F               // KP 4 5 6 7
    t[0x5B]=0x60; t[0x5C]=0x61; t[0x41]=0x63                               // KP 8 9 .
    t[0x4B]=0x54; t[0x43]=0x55; t[0x4E]=0x56; t[0x45]=0x57               // KP / * - +
    t[0x4C]=0x58; t[0x51]=0x67                                             // KP Enter KP =
    return t
}()

func hidForKey(_ keyCode: UInt16) -> UInt8? {
    let k = Int(keyCode)
    guard k < macToHID.count else { return nil }
    let h = macToHID[k]
    return h != 0 ? h : nil
}

func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
    switch keyCode {
    case 0x37, 0x36, 0x38, 0x3C, 0x3A, 0x3D, 0x3B, 0x3E, 0x39:
        return true
    default:
        return false
    }
}

func modifierIsDown(for keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
    let raw = flags.rawValue
    switch keyCode {
    case 0x37: return raw & 0x00000008 != 0  // Left Command
    case 0x36: return raw & 0x00000010 != 0  // Right Command
    case 0x38: return raw & 0x00000002 != 0  // Left Shift
    case 0x3C: return raw & 0x00000004 != 0  // Right Shift
    case 0x3A: return raw & 0x00000020 != 0  // Left Option
    case 0x3D: return raw & 0x00000040 != 0  // Right Option
    case 0x3B: return raw & 0x00000001 != 0  // Left Control
    case 0x3E: return raw & 0x00002000 != 0  // Right Control
    case 0x39: return flags.contains(.capsLock)
    default: return false
    }
}

// ASCII character → (HID keycode, needsShift) for paste-as-typing
let asciiToHID: [Character: (UInt8, Bool)] = [
    "a":(0x04,false), "b":(0x05,false), "c":(0x06,false), "d":(0x07,false),
    "e":(0x08,false), "f":(0x09,false), "g":(0x0A,false), "h":(0x0B,false),
    "i":(0x0C,false), "j":(0x0D,false), "k":(0x0E,false), "l":(0x0F,false),
    "m":(0x10,false), "n":(0x11,false), "o":(0x12,false), "p":(0x13,false),
    "q":(0x14,false), "r":(0x15,false), "s":(0x16,false), "t":(0x17,false),
    "u":(0x18,false), "v":(0x19,false), "w":(0x1A,false), "x":(0x1B,false),
    "y":(0x1C,false), "z":(0x1D,false),
    "A":(0x04,true), "B":(0x05,true), "C":(0x06,true), "D":(0x07,true),
    "E":(0x08,true), "F":(0x09,true), "G":(0x0A,true), "H":(0x0B,true),
    "I":(0x0C,true), "J":(0x0D,true), "K":(0x0E,true), "L":(0x0F,true),
    "M":(0x10,true), "N":(0x11,true), "O":(0x12,true), "P":(0x13,true),
    "Q":(0x14,true), "R":(0x15,true), "S":(0x16,true), "T":(0x17,true),
    "U":(0x18,true), "V":(0x19,true), "W":(0x1A,true), "X":(0x1B,true),
    "Y":(0x1C,true), "Z":(0x1D,true),
    "1":(0x1E,false), "2":(0x1F,false), "3":(0x20,false), "4":(0x21,false),
    "5":(0x22,false), "6":(0x23,false), "7":(0x24,false), "8":(0x25,false),
    "9":(0x26,false), "0":(0x27,false),
    "!":(0x1E,true), "@":(0x1F,true), "#":(0x20,true), "$":(0x21,true),
    "%":(0x22,true), "^":(0x23,true), "&":(0x24,true), "*":(0x25,true),
    "(":(0x26,true), ")":(0x27,true),
    " ":(0x2C,false),
    "-":(0x2D,false), "=":(0x2E,false), "[":(0x2F,false), "]":(0x30,false),
    "\\":(0x31,false), ";":(0x33,false), "'":(0x34,false), "`":(0x35,false),
    ",":(0x36,false), ".":(0x37,false), "/":(0x38,false),
    "_":(0x2D,true), "+":(0x2E,true), "{":(0x2F,true), "}":(0x30,true),
    "|":(0x31,true), ":":(0x33,true), "\"":(0x34,true), "~":(0x35,true),
    "<":(0x36,true), ">":(0x37,true), "?":(0x38,true),
]

// MARK: - Toolbar

extension NSToolbarItem.Identifier {
    static let video    = NSToolbarItem.Identifier("video")
    static let display  = NSToolbarItem.Identifier("display")
    static let audio    = NSToolbarItem.Identifier("audio")
    static let serial   = NSToolbarItem.Identifier("serial")
    static let keyboard = NSToolbarItem.Identifier("keyboard")
    static let ctrlAltDel = NSToolbarItem.Identifier("ctrlAltDel")
    static let mouse    = NSToolbarItem.Identifier("mouse")
    static let record   = NSToolbarItem.Identifier("record")
    static let debug    = NSToolbarItem.Identifier("debug")
}

// MARK: - Helper Functions

func findSerialPorts() -> [String] {
    let fm = FileManager.default
    guard let devs = try? fm.contentsOfDirectory(atPath: "/dev") else { return [] }
    var seen = Set<String>()
    var ports = [String]()
    for prefix in ["cu.usbmodem", "cu.usbserial", "cu.usb"] {
        for d in devs where d.hasPrefix(prefix) {
            let path = "/dev/" + d
            if seen.insert(path).inserted { ports.append(path) }
        }
    }
    return ports
}

func findCaptureDevices() -> [AVCaptureDevice] {
    var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
    if #available(macOS 14.0, *) { types.insert(.external, at: 0) }
    else { types.insert(.externalUnknown, at: 0) }
    return AVCaptureDevice.DiscoverySession(
        deviceTypes: types, mediaType: .video, position: .unspecified).devices
}

func findAudioCaptureDevices() -> [AVCaptureDevice] {
    var types: [AVCaptureDevice.DeviceType]
    if #available(macOS 14.0, *) { types = [.external, .microphone] }
    else { types = [.externalUnknown, .builtInMicrophone] }
    return AVCaptureDevice.DiscoverySession(
        deviceTypes: types, mediaType: .audio, position: .unspecified).devices
        .filter { !$0.uniqueID.contains("CADefaultDeviceAggregate") }
}

func findMatchingAudioDevice(for videoDevice: AVCaptureDevice) -> AVCaptureDevice? {
    let audioDevices = findAudioCaptureDevices()
    guard !audioDevices.isEmpty else { return nil }
    let vTransport = videoDevice.transportType
    let sameTransport = audioDevices.filter { $0.transportType == vTransport }
    if sameTransport.count == 1 { return sameTransport[0] }
    if sameTransport.count > 1 {
        let vName = videoDevice.localizedName.lowercased()
        let vMfr = videoDevice.manufacturer.lowercased()
        for dev in sameTransport {
            let aName = dev.localizedName.lowercased()
            let aMfr = dev.manufacturer.lowercased()
            if !vMfr.isEmpty && !aMfr.isEmpty && vMfr == aMfr { return dev }
            if vName.split(separator: " ").first == aName.split(separator: " ").first { return dev }
        }
        return sameTransport[0]
    }
    return nil
}

func audioDeviceID(for device: AVCaptureDevice) -> AudioDeviceID? {
    let uid = device.uniqueID as CFString
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var deviceID: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var qualifier = uid
    let err = withUnsafePointer(to: &qualifier) { ptr in
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            UInt32(MemoryLayout<CFString>.size), ptr,
            &size, &deviceID)
    }
    return err == noErr ? deviceID : nil
}

// Called by USB hardware when new input samples are available
func audioInputCallback(
    _ inRefCon: UnsafeMutableRawPointer,
    _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
    _ inBusNumber: UInt32,
    _ inNumberFrames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let app = Unmanaged<AppDelegate>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let inputUnit = app.audioInputUnit, let ring = app.audioRingBuffer,
          let ptr = app.audioRenderBuf else { return noErr }
    let samples = Int(inNumberFrames) * 2
    var abl = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(mNumberChannels: 2,
                              mDataByteSize: UInt32(samples * 4),
                              mData: UnsafeMutableRawPointer(ptr)))
    let err = AudioUnitRender(inputUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, &abl)
    if err == noErr {
        ring.write(ptr, count: samples)
    }
    return noErr
}

// Called by speakers when they need more samples
func audioOutputCallback(
    _ inRefCon: UnsafeMutableRawPointer,
    _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
    _ inBusNumber: UInt32,
    _ inNumberFrames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let app = Unmanaged<AppDelegate>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let ring = app.audioRingBuffer, let abl = ioData else { return noErr }
    let ptr = abl.pointee.mBuffers.mData!.assumingMemoryBound(to: Float32.self)
    let samples = Int(inNumberFrames) * 2
    ring.read(ptr, count: samples)
    if app.audioMuted { memset(ptr, 0, samples * 4) }
    return noErr
}

func fourCC(_ format: AVCaptureDevice.Format) -> String {
    let sub = CMFormatDescriptionGetMediaSubType(format.formatDescription)
    let chars = [sub >> 24, sub >> 16, sub >> 8, sub].map { Character(UnicodeScalar(UInt8($0 & 0xFF))) }
    return String(chars)
}

func calcRenderRect(vw: Int, vh: Int, ww: CGFloat, wh: CGFloat) -> NSRect {
    guard vw > 0, vh > 0, ww > 0, wh > 0 else { return NSMakeRect(0,0,ww,wh) }
    let vr = CGFloat(vw)/CGFloat(vh), wr = ww/wh
    if vr > wr { let rh = ww/vr; return NSMakeRect(0, (wh-rh)/2, ww, rh) }
    else { let rw = wh*vr; return NSMakeRect((ww-rw)/2, 0, rw, wh) }
}

func pixelToNorm(_ px: CGFloat, _ py: CGFloat, _ r: NSRect, _ invW: CGFloat, _ invH: CGFloat) -> (Double,Double)? {
    let lx = px - r.origin.x, ly = py - r.origin.y
    guard lx >= 0, ly >= 0, lx < r.width, ly < r.height else { return nil }
    return (lx * invW, ly * invH)
}

func compactDate(_ date: Date?) -> String {
    guard let date else { return "" }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

func byteHex(_ bytes: [UInt8]?) -> String {
    guard let bytes, !bytes.isEmpty else { return "" }
    return bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func packetData(from raw: [UInt8]) -> [UInt8]? {
    guard raw.count >= 6 else { return nil }
    for i in 0...(raw.count - 2) {
        guard raw[i] == 0x57, raw[i + 1] == 0xAB, i + 5 < raw.count else { continue }
        let len = Int(raw[i + 4])
        let dataStart = i + 5
        let sumIndex = dataStart + len
        guard sumIndex < raw.count else { continue }
        var sum: UInt32 = 0
        for j in i..<sumIndex { sum += UInt32(raw[j]) }
        guard UInt8(sum & 0xFF) == raw[sumIndex] else { continue }
        return Array(raw[dataStart..<sumIndex])
    }
    return nil
}

func parseNanoKVMInfo(_ raw: [UInt8]?) -> NanoKVMInfo? {
    guard let raw, let data = packetData(from: raw), data.count >= 3, data[0] >= 0x30 else {
        return nil
    }
    let version = 1.0 + Double(data[0] - 0x30) / 10.0
    return NanoKVMInfo(
        chipVersion: String(format: "V%.1f", version),
        isConnected: data[1] != 0,
        numLock: (data[2] & 0x01) != 0,
        capsLock: (data[2] & 0x02) != 0,
        scrollLock: (data[2] & 0x04) != 0)
}

func architectureName() -> String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "unknown"
    #endif
}

func frameDurationFPS(_ time: CMTime) -> Double? {
    guard time.isValid, !time.isIndefinite, time.seconds > 0 else { return nil }
    return 1.0 / time.seconds
}

func formatFrameRates(_ format: AVCaptureDevice.Format) -> [[String: Double]] {
    format.videoSupportedFrameRateRanges.map {
        ["min": $0.minFrameRate, "max": $0.maxFrameRate]
    }
}

func formatExtensionValue(_ format: AVCaptureDevice.Format, _ key: CFString) -> String {
    guard let ext = CMFormatDescriptionGetExtensions(format.formatDescription) as NSDictionary? else {
        return ""
    }
    guard let value = ext[key] else { return "" }
    return String(describing: value)
}

func shortcutBadgeImage(_ text: String) -> NSImage {
    let size = NSSize(width: 30, height: 22)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.controlAccentColor.setFill()
    let rect = NSRect(x: 1, y: 2, width: size.width - 2, height: size.height - 4)
    NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
        .foregroundColor: NSColor.white
    ]
    let textSize = text.size(withAttributes: attrs)
    let textRect = NSRect(
        x: (size.width - textSize.width) / 2,
        y: (size.height - textSize.height) / 2 + 0.5,
        width: textSize.width,
        height: textSize.height)
    text.draw(in: textRect, withAttributes: attrs)
    image.unlockFocus()
    image.isTemplate = false
    return image
}

func makeTransparentCursor() -> NSCursor {
    let size = NSSize(width: 16, height: 16)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width),
        pixelsHigh: Int(size.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0)!
    if let data = rep.bitmapData {
        memset(data, 0, rep.bytesPerRow * rep.pixelsHigh)
    }
    rep.size = size
    let image = NSImage(size: size)
    image.addRepresentation(rep)
    return NSCursor(image: image, hotSpot: .zero)
}

let transparentVideoCursor = makeTransparentCursor()

class VideoView: NSView {
    weak var app: AppDelegate?

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        app?.shouldAcceptFirstMouse(event) ?? false
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let app else { return }
        let videoRect = app.videoCursorRect(in: self)
        guard !videoRect.isEmpty else { return }
        addCursorRect(
            videoRect,
            cursor: app.shouldUseTransparentVideoCursor() ? transparentVideoCursor : .arrow)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let app = app, app.serial.isOpen, !app.isResizing else { return }
        if event.modifierFlags.contains(.command) { return }
        if let h = hidForKey(event.keyCode) { app.serial.sendKeyboard(app.kb.keyDown(h)) }
    }

    override func keyUp(with event: NSEvent) {
        guard let app = app, app.serial.isOpen, !app.isResizing else { return }
        if let h = hidForKey(event.keyCode) { app.serial.sendKeyboard(app.kb.keyUp(h)) }
    }

    override func flagsChanged(with event: NSEvent) {
        guard let app = app, app.serial.isOpen, !app.isResizing else { return }
        if (event.keyCode == 0x37 || event.keyCode == 0x36) &&
            !app.shouldCaptureKeyboardEvent(event) { return }
        if let h = hidForKey(event.keyCode) {
            let isDown = modifierIsDown(for: event.keyCode, flags: event.modifierFlags)
            app.serial.sendKeyboard(isDown ? app.kb.keyDown(h) : app.kb.keyUp(h))
        }
    }

    // MARK: - Mouse move / drag

    private func handleMove(_ event: NSEvent) {
        guard let app else { return }
        let viewLoc = convert(event.locationInWindow, from: nil)
        app.recordMouseEvent(kind: "move")
        guard app.prepareMouseEvent(event, viewLoc: viewLoc) else { return }
        guard app.serial.isOpen, !app.isResizing else { return }
        if Config.mouseAbsolute {
            if let pos = pixelToNorm(viewLoc.x, bounds.height - viewLoc.y, app.rRect, app.rRectInvW, app.rRectInvH) {
                app.lastPos = pos; app.pendingMove = pos
            }
        } else {
            let dx = Int(event.deltaX), dy = Int(event.deltaY)
            if dx != 0 || dy != 0 {
                app.pendingRelDx += dx; app.pendingRelDy += dy
            }
        }
    }

    override func mouseMoved(with event: NSEvent) { handleMove(event) }
    override func mouseDragged(with event: NSEvent) { handleMove(event) }
    override func rightMouseDragged(with event: NSEvent) { handleMove(event) }
    override func otherMouseDragged(with event: NSEvent) { handleMove(event) }
    override func mouseEntered(with event: NSEvent) {
        guard let app else { return }
        let viewLoc = convert(event.locationInWindow, from: nil)
        _ = app.prepareMouseEvent(event, viewLoc: viewLoc)
    }
    override func mouseExited(with event: NSEvent) {
        app?.leaveVideoInputRegion(event)
    }

    // MARK: - Mouse down / up

    private func handleDown(_ event: NSEvent) {
        guard let app else { return }
        let viewLoc = convert(event.locationInWindow, from: nil)
        app.recordMouseEvent(kind: "button")
        guard app.prepareMouseEvent(event, viewLoc: viewLoc) else { return }
        guard app.serial.isOpen, !app.isResizing else { return }
        app.mouse.buttonDown(event.buttonNumber)
        if Config.mouseAbsolute {
            if let pos = pixelToNorm(viewLoc.x, bounds.height - viewLoc.y, app.rRect, app.rRectInvW, app.rRectInvH) {
                app.lastPos = pos
            }
            app.serial.sendMouseAbsolute(app.mouse.build(nx: app.lastPos.0, ny: app.lastPos.1))
        } else {
            app.serial.sendMouseRelative(app.mouse.buildRelative(dx: 0, dy: 0))
        }
        app.recordMouseReport()
    }

    private func handleUp(_ event: NSEvent) {
        guard let app else { return }
        let viewLoc = convert(event.locationInWindow, from: nil)
        app.recordMouseEvent(kind: "button")
        guard app.prepareMouseEvent(event, viewLoc: viewLoc) else { return }
        guard app.serial.isOpen, !app.isResizing else { return }
        app.mouse.buttonUp(event.buttonNumber)
        app.sendCurrentMouseButtons()
    }

    override func mouseDown(with event: NSEvent) { handleDown(event) }
    override func rightMouseDown(with event: NSEvent) { handleDown(event) }
    override func otherMouseDown(with event: NSEvent) { handleDown(event) }
    override func mouseUp(with event: NSEvent) { handleUp(event) }
    override func rightMouseUp(with event: NSEvent) { handleUp(event) }
    override func otherMouseUp(with event: NSEvent) { handleUp(event) }

    // MARK: - Scroll

    override func scrollWheel(with event: NSEvent) {
        guard let app = app, app.serial.isOpen, !app.isResizing else { return }
        let viewLoc = convert(event.locationInWindow, from: nil)
        guard app.prepareMouseEvent(event, viewLoc: viewLoc) else { return }
        app.recordMouseEvent(kind: "wheel")
        app.scrollAccum += event.scrollingDeltaY * Config.scrollSpeed * Double(Config.scrollDirection)
        let s = Int(app.scrollAccum)
        guard s != 0 else { return }
        app.scrollAccum -= Double(s)
        let clamped = max(-127, min(127, s))
        if Config.mouseAbsolute {
            app.serial.sendMouseAbsolute(app.mouse.build(nx: app.lastPos.0, ny: app.lastPos.1, scroll: clamped))
        } else {
            app.serial.sendMouseRelative(app.mouse.buildRelative(dx: 0, dy: 0, scroll: clamped))
        }
        app.recordMouseReport()
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
                   NSToolbarDelegate, NSMenuDelegate,
                   AVCaptureVideoDataOutputSampleBufferDelegate,
                   AVCaptureFileOutputRecordingDelegate {
    let serial = SerialPort()
    var session: AVCaptureSession?
    var previewLayer: AVCaptureVideoPreviewLayer?
    var window: NSWindow!
    var videoView: VideoView!
    let kb = KeyboardHID()
    let mouse = MouseHID()
    var lastPos = (0.5, 0.5)
    var pendingMove: (Double, Double)?
    var pendingRelDx = 0, pendingRelDy = 0
    var scrollAccum: Double = 0
    var mouseInsideVideo = false
    var cursorActuallyHidden = false
    var mouseEventCount = 0
    var mouseMoveEventCount = 0
    var mouseReportCount = 0
    var recentMouseEvents: [TimeInterval] = []
    var recentMouseMoves: [TimeInterval] = []
    var recentMouseReports: [TimeInterval] = []
    var videoW = 1920, videoH = 1080
    var rRect = NSRect.zero
    var rRectInvW: CGFloat = 0
    var rRectInvH: CGFloat = 0

    // Capture device tracking
    var currentDevice: AVCaptureDevice?
    var currentInput: AVCaptureDeviceInput?
    var requestedFrameRate: VideoFrameRateChoice = .auto
    var displayColor = DisplayColor.recommended

    // Serial tracking
    var currentSerialPath: String?
    var lastInfoRaw: [UInt8]?
    var lastInfoUpdatedAt: Date?
    var lastInfoRequestAt: Date?

    // Screenshot
    enum ScreenshotFormat: String { case png, jpeg, heic }
    var screenshotFormat: ScreenshotFormat = .png
    var screenshotQuality: Double = 0.85

    // Recording
    var isRecording = false
    var recordingCodec: AVVideoCodecType = .hevc
    var movieFileOutput: AVCaptureMovieFileOutput?

    // Audio
    var audioDevice: AVCaptureDevice?
    var audioInput: AVCaptureDeviceInput?
    var audioInputUnit: AudioUnit?
    var audioOutputUnit: AudioUnit?
    var audioRingBuffer: AudioRingBuffer?
    var audioMuted = false
    var audioRenderBuf: UnsafeMutablePointer<Float32>?
    // Mouse flush timer
    var mouseFlushTimer: Timer?

    // Mouse jiggler
    var jigglerTimer: Timer?
    var isJiggling = false

    // Paste state
    var isPasting = false

    // Background refresh
    var frozenLayer: CALayer?
    var backgroundStatusLayer: CATextLayer?
    var refreshTimer: Timer?
    var isBackgroundRefresh = false
    var backgroundRefreshInterval: TimeInterval = Config.backgroundRefreshDefault
    var backgroundRefreshStartedAt: Date?
    var lastBackgroundSnapshotAt: Date?
    var sessionWatchdog: DispatchWorkItem?
    var inactivePolicyWorkItem: DispatchWorkItem?
    var waitingForForegroundFrame = false
    var foregroundResumeFramesNeeded = 0
    var resumeShieldGeneration = 0
    var pendingUnfreezeWorkItem: DispatchWorkItem?
    var frameOutput: AVCaptureVideoDataOutput?
    let frameQueue = DispatchQueue(label: "com.nanokvm.frame", qos: .userInitiated)
    let sessionQueue = DispatchQueue(label: "com.nanokvm.session", qos: .userInitiated)
    var latestPixelBuffer: CVPixelBuffer?
    var actualFrameCount = 0
    var actualFrameFps: Double = 0
    var droppedFrameEstimate = 0
    var lastFramePTS: CMTime?
    var frameSampleStartedAt = CFAbsoluteTimeGetCurrent()
    var frameSampleCount = 0
    // Resize tracking
    var isResizing = false

    // Debug panel
    var debugWindow: NSPanel?
    var debugTextView: NSTextView?
    var debugTimer: Timer?
    var debugCloseObserver: NSObjectProtocol?
    var localMouseMonitor: Any?
    var globalMouseMonitor: Any?
    var localKeyboardMonitor: Any?
    var capturedKeyCodes = Set<UInt16>()
    var capturedModifierStates: [UInt16: Bool] = [:]
    let configuredToolbarWindows = NSHashTable<NSWindow>.weakObjects()
    var toolbarCursorRestoreScheduled = false
    var toolbarReturnPosition: (Double, Double)?
    var fullscreenToolbarPointerActive = false
    var mouseInputBarrierUntil: TimeInterval = 0
    var mouseInputBarrierWaitsForButtonsUp = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ n: Notification) {
        let policyVersion = UserDefaults.standard.integer(forKey: "backgroundRefreshPolicyVersion")
        let savedBackgroundRefresh = UserDefaults.standard.object(forKey: "backgroundRefresh") as? Double
        if policyVersion < Config.backgroundRefreshPolicyVersion {
            // Migrate earlier defaults while preserving deliberately selected modes.
            backgroundRefreshInterval =
                savedBackgroundRefresh == nil ||
                savedBackgroundRefresh == Config.adaptiveRefreshFast ||
                savedBackgroundRefresh == Config.adaptiveRefreshSlow
                ? Config.backgroundRefreshDefault
                : savedBackgroundRefresh!
            UserDefaults.standard.set(backgroundRefreshInterval, forKey: "backgroundRefresh")
            UserDefaults.standard.set(
                Config.backgroundRefreshPolicyVersion,
                forKey: "backgroundRefreshPolicyVersion")
        } else if let savedBackgroundRefresh {
            backgroundRefreshInterval = savedBackgroundRefresh
        }
        requestedFrameRate = VideoFrameRateChoice(
            rawValue: UserDefaults.standard.string(forKey: "videoFrameRate") ?? "auto")
        displayColor = DisplayColor(
            brightness: UserDefaults.standard.object(forKey: "displayBrightness") as? Double
                ?? DisplayColor.recommended.brightness,
            contrast: UserDefaults.standard.object(forKey: "displayContrast") as? Double
                ?? DisplayColor.recommended.contrast,
            saturation: UserDefaults.standard.object(forKey: "displaySaturation") as? Double
                ?? DisplayColor.recommended.saturation)
        if let codecStr = UserDefaults.standard.string(forKey: "recordingCodec") {
            recordingCodec = AVVideoCodecType(rawValue: codecStr)
        }
        if let fmtStr = UserDefaults.standard.string(forKey: "screenshotFormat"),
           let fmt = ScreenshotFormat(rawValue: fmtStr) {
            screenshotFormat = fmt
        }
        let savedQuality = UserDefaults.standard.integer(forKey: "screenshotQuality")
        if savedQuality > 0 { screenshotQuality = Double(savedQuality) / 100.0 }
        loadInputPreferences()
        migrateVideoFormatPreferences()
        setupSerial(); setupCapture(); setupWindow()
        setupMouseMonitor()
        setupKeyboardMonitor()
        if serial.isOpen { startMouseFlush() }
    }

    func loadInputPreferences() {
        if UserDefaults.standard.object(forKey: "cursorHiddenPreferred") != nil {
            Config.cursorHiddenPreferred = UserDefaults.standard.bool(forKey: "cursorHiddenPreferred")
        }
        if UserDefaults.standard.object(forKey: "mouseAbsolute") != nil {
            Config.mouseAbsolute = UserDefaults.standard.bool(forKey: "mouseAbsolute")
        }
        if UserDefaults.standard.object(forKey: "scrollDirection") != nil {
            Config.scrollDirection = UserDefaults.standard.integer(forKey: "scrollDirection") >= 0 ? 1 : -1
        }
        if UserDefaults.standard.object(forKey: "scrollSpeed") != nil {
            let speed = UserDefaults.standard.double(forKey: "scrollSpeed")
            if speed > 0 { Config.scrollSpeed = speed }
        }
        if UserDefaults.standard.object(forKey: "keyboardCaptureHostShortcuts") != nil {
            Config.keyboardCaptureHostShortcuts =
                UserDefaults.standard.bool(forKey: "keyboardCaptureHostShortcuts")
        }
    }

    func migrateVideoFormatPreferences() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: "videoFormatPolicyVersion") < Config.videoFormatPolicyVersion
        else { return }
        let explicit = defaults.bool(forKey: "videoResolutionExplicit")
        let savedW = defaults.integer(forKey: "videoW")
        let savedH = defaults.integer(forKey: "videoH")
        if !explicit, savedW == 3840, savedH == 2160 {
            defaults.set(Config.preferredDefaultVideoW, forKey: "videoW")
            defaults.set(Config.preferredDefaultVideoH, forKey: "videoH")
        }
        defaults.set(Config.videoFormatPolicyVersion, forKey: "videoFormatPolicyVersion")
    }

    func setupMouseMonitor() {
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .mouseMoved, .mouseEntered, .mouseExited, .cursorUpdate,
                .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                .leftMouseDown, .rightMouseDown, .otherMouseDown,
                .leftMouseUp, .rightMouseUp, .otherMouseUp
            ]) {
            [weak self] event in
            self?.handleLocalMouseEvent(event)
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [
                .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                .leftMouseDown, .rightMouseDown, .otherMouseDown,
                .leftMouseUp, .rightMouseUp, .otherMouseUp,
                .scrollWheel
            ]) { [weak self] event in
                self?.handleGlobalMouseEvent(event)
            }
    }

    func setupKeyboardMonitor() {
        localKeyboardMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handleLocalKeyboardEvent(event) ?? event
        }
    }

    func shouldCaptureKeyboardEvent(_ event: NSEvent) -> Bool {
        guard Config.keyboardCaptureHostShortcuts,
              serial.isOpen,
              !isResizing,
              NSApp.isActive,
              window?.isKeyWindow == true,
              window?.styleMask.contains(.fullScreen) == true else { return false }
        if capturedKeyCodes.contains(event.keyCode) ||
            capturedModifierStates[event.keyCode] != nil {
            return true
        }
        return mouseInsideVideo && !isEventOverFullscreenToolbar(event)
    }

    func shouldKeepHostShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        else { return false }
        return event.keyCode == 0x03 // Command+F: local fullscreen toggle
    }

    func handleLocalKeyboardEvent(_ event: NSEvent) -> NSEvent? {
        guard shouldCaptureKeyboardEvent(event) else { return event }
        guard !shouldKeepHostShortcut(event) else { return event }
        guard let hid = hidForKey(event.keyCode) else { return nil }

        switch event.type {
        case .keyDown:
            capturedKeyCodes.insert(event.keyCode)
            serial.sendKeyboard(kb.keyDown(hid))
        case .keyUp:
            capturedKeyCodes.remove(event.keyCode)
            serial.sendKeyboard(kb.keyUp(hid))
        case .flagsChanged:
            let isDown = modifierIsDown(for: event.keyCode, flags: event.modifierFlags)
            let wasDown = capturedModifierStates[event.keyCode] ?? false
            guard isDown != wasDown || isModifierKeyCode(event.keyCode) else { return nil }
            if isDown {
                capturedModifierStates[event.keyCode] = true
            } else {
                capturedModifierStates[event.keyCode] = nil
            }
            serial.sendKeyboard(isDown ? kb.keyDown(hid) : kb.keyUp(hid))
        default:
            break
        }
        return nil
    }

    func resetCapturedKeyboardState() {
        guard !capturedKeyCodes.isEmpty || !capturedModifierStates.isEmpty else { return }
        capturedKeyCodes.removeAll()
        capturedModifierStates.removeAll()
        if serial.isOpen {
            serial.sendKeyboard(kb.releaseAll())
        }
    }

    func handleLocalMouseEvent(_ event: NSEvent) {
        guard window != nil, videoView != nil else { return }
        if shouldSuppressMouseInput(event) {
            return
        }
        guard event.window === window else {
            leaveVideoInputRegion(event)
            enforceFullscreenToolbarCursor(on: event.window)
            showSystemCursorIfHidden()
            return
        }
        guard isWindowPointInsideVideoContent(event.locationInWindow) else {
            leaveVideoInputRegion(event)
            showSystemCursorIfHidden()
            return
        }
        let viewLoc = videoView.convert(event.locationInWindow, from: nil)
        _ = prepareMouseEvent(event, viewLoc: viewLoc)
    }

    func handleGlobalMouseEvent(_ event: NSEvent) {
        guard window != nil else { return }
        leaveVideoInputRegion(event)
        if event.type == .leftMouseDown ||
            event.type == .rightMouseDown ||
            event.type == .otherMouseDown {
            releaseMouseButtons()
            beginMouseInputBarrier(duration: 0.35, waitForButtonsUp: true)
        }
        showSystemCursorIfHidden()
    }

    func shouldAcceptFirstMouse(_ event: NSEvent?) -> Bool {
        guard NSApp.isActive, window?.isKeyWindow == true else { return false }
        if let event, shouldSuppressMouseInput(event) { return false }
        return true
    }

    func beginMouseInputBarrier(duration: TimeInterval, waitForButtonsUp: Bool) {
        cancelPendingMouseMotion()
        releaseMouseButtons()
        setMouseInsideVideo(false)
        mouseInputBarrierUntil = max(mouseInputBarrierUntil, CFAbsoluteTimeGetCurrent() + duration)
        mouseInputBarrierWaitsForButtonsUp =
            mouseInputBarrierWaitsForButtonsUp ||
            (waitForButtonsUp && NSEvent.pressedMouseButtons != 0)
    }

    func shouldSuppressMouseInput(_ event: NSEvent) -> Bool {
        let pressedButtons = NSEvent.pressedMouseButtons
        if mouseInputBarrierWaitsForButtonsUp {
            if pressedButtons == 0 && !isMouseButtonOrDragEvent(event) {
                mouseInputBarrierWaitsForButtonsUp = false
            } else {
                leaveVideoInputRegion(event)
                showSystemCursorIfHidden()
                return true
            }
        }
        if CFAbsoluteTimeGetCurrent() < mouseInputBarrierUntil {
            leaveVideoInputRegion(event)
            showSystemCursorIfHidden()
            return true
        }
        mouseInputBarrierUntil = 0
        return false
    }

    func isMouseButtonOrDragEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseUp, .rightMouseUp, .otherMouseUp,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return true
        default:
            return false
        }
    }

    func eventScreenPoint(_ event: NSEvent) -> NSPoint {
        event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    func isEventOverFullscreenToolbar(_ event: NSEvent) -> Bool {
        if let eventWindow = event.window,
           eventWindow !== window,
           String(describing: type(of: eventWindow)).contains("ToolbarFullScreenWindow") {
            return true
        }
        return isScreenPointOverFullscreenToolbar(eventScreenPoint(event))
    }

    func isScreenPointInFullscreenToolbarRevealZone(_ point: NSPoint) -> Bool {
        guard window.styleMask.contains(.fullScreen),
              let screen = window.screen else { return false }
        return screen.frame.contains(point) && screen.frame.maxY - point.y <= 72
    }

    func isEventInFullscreenToolbarRevealZone(_ event: NSEvent) -> Bool {
        isScreenPointInFullscreenToolbarRevealZone(eventScreenPoint(event))
    }

    func cancelPendingMouseMotion() {
        pendingMove = nil
        pendingRelDx = 0
        pendingRelDy = 0
        scrollAccum = 0
    }

    func leaveVideoInputRegion(_ event: NSEvent? = nil) {
        cancelPendingMouseMotion()
        setMouseInsideVideo(false)
        if let event {
            if isEventOverFullscreenToolbar(event) {
                restoreRemoteMouseAfterToolbarEntry()
            }
            releaseRemoteMouseButtonIfNeeded(event)
        }
    }

    func restoreRemoteMouseAfterToolbarEntry() {
        guard let pos = toolbarReturnPosition else { return }
        toolbarReturnPosition = nil
        guard Config.mouseAbsolute, serial.isOpen else { return }
        lastPos = pos
        serial.sendMouseAbsolute(mouse.build(nx: pos.0, ny: pos.1))
        recordMouseReport()
    }

    func handleFullscreenToolbarAtCurrentMouseLocation() -> Bool {
        guard toolbarReturnPosition != nil || fullscreenToolbarPointerActive else { return false }
        let mouseLocation = NSEvent.mouseLocation
        guard isScreenPointOverFullscreenToolbar(mouseLocation) else {
            fullscreenToolbarPointerActive = false
            if !isScreenPointInFullscreenToolbarRevealZone(mouseLocation) {
                toolbarReturnPosition = nil
            }
            return false
        }
        cancelPendingMouseMotion()
        if !fullscreenToolbarPointerActive {
            fullscreenToolbarPointerActive = true
            setMouseInsideVideo(false)
            restoreRemoteMouseAfterToolbarEntry()
            showSystemCursorIfHidden()
        }
        return true
    }

    func prepareMouseEvent(_ event: NSEvent, viewLoc: NSPoint) -> Bool {
        guard !shouldSuppressMouseInput(event) else { return false }
        guard !isEventOverFullscreenToolbar(event) else {
            leaveVideoInputRegion(event)
            return false
        }
        if isEventInFullscreenToolbarRevealZone(event) {
            if toolbarReturnPosition == nil {
                toolbarReturnPosition = lastPos
            }
        } else {
            toolbarReturnPosition = nil
        }
        updateMouseInsideVideo(viewLoc)
        guard mouseInsideVideo else {
            leaveVideoInputRegion(event)
            return false
        }
        return true
    }

    func releaseRemoteMouseButtonIfNeeded(_ event: NSEvent) {
        switch event.type {
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard serial.isOpen, mouse.isButtonDown(event.buttonNumber) else { return }
            mouse.buttonUp(event.buttonNumber)
            sendCurrentMouseButtons()
        default:
            return
        }
    }

    func sendCurrentMouseButtons() {
        if Config.mouseAbsolute {
            serial.sendMouseAbsolute(mouse.build(nx: lastPos.0, ny: lastPos.1))
        } else {
            serial.sendMouseRelative(mouse.buildRelative(dx: 0, dy: 0))
        }
        recordMouseReport()
    }

    func releaseMouseButtons() {
        guard mouse.hasButtonsDown else { return }
        mouse.releaseButtons()
        guard serial.isOpen else { return }
        sendCurrentMouseButtons()
    }

    func updateMouseLocationFromSystem() {
        guard window != nil, videoView != nil,
              window.isKeyWindow, NSApp.isActive else {
            leaveVideoInputRegion()
            return
        }
        let windowLoc = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard isWindowPointInsideVideoContent(windowLoc) else {
            leaveVideoInputRegion()
            return
        }
        let viewLoc = videoView.convert(windowLoc, from: nil)
        updateMouseInsideVideo(viewLoc)
    }

    func isWindowPointInsideVideoContent(_ windowLoc: NSPoint) -> Bool {
        guard let contentView = window.contentView else { return false }
        let screenPoint = window.convertPoint(toScreen: windowLoc)
        guard !isScreenPointOverFullscreenToolbar(screenPoint) else { return false }
        // contentLayoutRect tracks the area left after AppKit exposes title-bar/fullscreen
        // toolbar chrome. It changes as fullscreen chrome animates in and out.
        guard window.contentLayoutRect.contains(windowLoc) else { return false }
        let contentLoc = contentView.convert(windowLoc, from: nil)
        guard contentView.bounds.contains(contentLoc) else { return false }
        guard let frameView = contentView.superview else {
            return true
        }
        let frameLoc = frameView.convert(windowLoc, from: nil)
        guard frameView.bounds.contains(frameLoc),
              let hitView = frameView.hitTest(frameLoc) else { return false }
        return hitView === contentView || hitView.isDescendant(of: contentView)
    }

    func fullscreenToolbarWindows() -> [NSWindow] {
        NSApp.windows.filter {
            $0 !== window && String(describing: type(of: $0)).contains("ToolbarFullScreenWindow")
        }
    }

    func isScreenPointOverFullscreenToolbar(_ screenPoint: NSPoint) -> Bool {
        fullscreenToolbarWindows().contains {
            guard $0.isVisible, $0.alphaValue > 0.01,
                  let screenFrame = $0.screen?.frame ?? window.screen?.frame else { return false }
            return $0.frame.intersection(screenFrame).contains(screenPoint)
        }
    }

    func startMouseFlush() {
        guard mouseFlushTimer == nil else { return }
        let t = Timer(timeInterval: Config.flushInterval, repeats: true) {
            [weak self] _ in self?.flushMouse()
        }
        RunLoop.main.add(t, forMode: .common)
        mouseFlushTimer = t
    }

    func stopMouseFlush() {
        mouseFlushTimer?.invalidate()
        mouseFlushTimer = nil
    }

    func setupSerial() {
        guard let port = findSerialPorts().first else { print("No serial port. Video only."); return }
        print("Serial: " + port)
        if serial.open(path: port) {
            currentSerialPath = port
            requestDeviceInfo()
        } else { print("Failed to open " + port) }
    }

    func formatScore(_ format: AVCaptureDevice.Format) -> Int {
        let sub = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        switch sub {
        case 0x34323076: return 4                                      // 420v (NV12) — raw, zero decode
        case 0x6A706567, 0x646D6231, 0x61766331, 0x68766331: return 3 // jpeg, dmb1, avc1, hvc1
        case 0x79757673: return 2                                      // yuvs (YUV422)
        default: return 0
        }
    }

    func formatSupports(_ format: AVCaptureDevice.Format, fps: Double?) -> Bool {
        guard let fps else { return true }
        return format.videoSupportedFrameRateRanges.contains {
            fps >= $0.minFrameRate - 0.01 && fps <= $0.maxFrameRate + 0.01
        }
    }

    func activeFrameRate(for device: AVCaptureDevice) -> Double? {
        frameDurationFPS(device.activeVideoMaxFrameDuration) ??
            frameDurationFPS(device.activeVideoMinFrameDuration) ??
            requestedFrameRate.fps
    }

    func frameRateText(_ fps: Double?) -> String {
        guard let fps, fps.isFinite, fps > 0 else { return "Auto" }
        if abs(fps.rounded() - fps) < 0.01 {
            return "\(Int(fps.rounded())) fps"
        }
        return String(format: "%.2f fps", fps)
    }

    func applyFrameRate(to device: AVCaptureDevice) {
        guard let fps = requestedFrameRate.fps,
              let range = device.activeFormat.videoSupportedFrameRateRanges.first(where: {
                  fps >= $0.minFrameRate - 0.01 && fps <= $0.maxFrameRate + 0.01
              }) else { return }
        let isDiscreteRate =
            abs(range.minFrameRate - fps) < 0.01 &&
            abs(range.maxFrameRate - fps) < 0.01
        let duration = isDiscreteRate
            ? range.minFrameDuration
            : CMTimeMakeWithSeconds(1.0 / fps, preferredTimescale: 1_000_000_000)
        var error: NSError?
        if !NanoKVMSetFrameRate(device, duration, &error) {
            let reason = error?.localizedDescription ?? "driver rejected the requested timing"
            print("Frame rate request \(frameRateText(fps)) unavailable: \(reason)")
        }
    }

    func bestFormat(for device: AVCaptureDevice, width: Int? = nil, height: Int? = nil) -> AVCaptureDevice.Format? {
        let requestedFPS = requestedFrameRate.fps
        let matchingFPS = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            if let width, let height, (Int(dims.width) != width || Int(dims.height) != height) {
                return false
            }
            return format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 5 } &&
                formatSupports(format, fps: requestedFPS)
        }
        let candidates = matchingFPS.isEmpty ? device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            if let width, let height, (Int(dims.width) != width || Int(dims.height) != height) {
                return false
            }
            return format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 5 }
        } : matchingFPS

        var bestFormat: AVCaptureDevice.Format?
        var bestPixels: Int32 = 0
        var bestScore = -1
        for format in candidates {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let pixels = dims.width * dims.height
            let score = formatScore(format)
            if score > bestScore || (score == bestScore && pixels > bestPixels) {
                bestPixels = pixels; bestFormat = format; bestScore = score
            }
        }
        return bestFormat
    }

    func applyFormat(_ format: AVCaptureDevice.Format, to device: AVCaptureDevice, save: Bool = true) {
        if isRecording { stopRecording() }
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.unlockForConfiguration()
        } catch { print("Failed to set format: \(error)"); return }
        videoW = Int(dims.width); videoH = Int(dims.height)
        if save {
            UserDefaults.standard.set(videoW, forKey: "videoW")
            UserDefaults.standard.set(videoH, forKey: "videoH")
            UserDefaults.standard.set(true, forKey: "videoResolutionExplicit")
        }
        window?.contentAspectRatio = NSSize(width: videoW, height: videoH)
        applyFrameRate(to: device)
        resetFrameMetrics()
        print("Active: \(videoW)x\(videoH) [\(fourCC(format))] \(frameRateText(activeFrameRate(for: device)))")
        refreshDebugPanel()
    }

    func selectInitialFormat(for device: AVCaptureDevice) {
        let savedW = UserDefaults.standard.integer(forKey: "videoW")
        let savedH = UserDefaults.standard.integer(forKey: "videoH")

        // Try to restore saved resolution
        if savedW > 0 && savedH > 0,
           let match = bestFormat(for: device, width: savedW, height: savedH) {
            applyFormat(match, to: device, save: false)
            return
        }

        // Conservative default: prefer 1080p over the capture dongle's highest mode.
        if let preferred = bestFormat(
            for: device,
            width: Config.preferredDefaultVideoW,
            height: Config.preferredDefaultVideoH) {
            applyFormat(preferred, to: device, save: false)
            return
        }

        // Last resort: pick a usable format, but do not persist it as a user choice.
        guard let chosen = bestFormat(for: device) else { return }
        applyFormat(chosen, to: device, save: false)
    }

    func setupCapture() {
        let devices = findCaptureDevices()
        guard let dev = devices.first(where: {
            let n = $0.localizedName.lowercased()
            return !n.contains("facetime") && !n.contains("iphone")
        }) ?? devices.first else { print("No capture device."); return }
        print("Camera: " + dev.localizedName)
        // Log available formats per resolution
        var fmtsByRes: [String: [String]] = [:]
        for format in dev.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let key = "\(dims.width)x\(dims.height)"
            let cc = fourCC(format)
            var formats = fmtsByRes[key] ?? []
            if !formats.contains(cc) { formats.append(cc) }
            fmtsByRes[key] = formats
        }
        for (res, formats) in fmtsByRes.sorted(by: { $0.key > $1.key }) {
            print("  \(res): \(formats.joined(separator: ", "))")
        }
        guard let input = try? AVCaptureDeviceInput(device: dev) else { return }
        let sess = AVCaptureSession()
        sess.sessionPreset = .high
        if sess.canAddInput(input) { sess.addInput(input) }
        selectInitialFormat(for: dev)
        let fOutput = AVCaptureVideoDataOutput()
        fOutput.alwaysDiscardsLateVideoFrames = true
        fOutput.setSampleBufferDelegate(self, queue: frameQueue)
        if sess.canAddOutput(fOutput) { sess.addOutput(fOutput) }
        frameOutput = fOutput
        session = sess; currentDevice = dev; currentInput = input

        sessionQueue.async { sess.startRunning() }
    }

    func setupAudioDevice(_ device: AVCaptureDevice, in sess: AVCaptureSession) {
        // Add input to capture session (needed for recording via AVCaptureAudioDataOutput)
        guard let input = try? AVCaptureDeviceInput(device: device) else { return }
        sess.beginConfiguration()
        if sess.canAddInput(input) { sess.addInput(input) }
        else { sess.commitConfiguration(); return }
        sess.commitConfiguration()
        audioDevice = device
        audioInput = input

        // CoreAudio pass-through: HAL input (USB) → ring buffer → default output
        guard let devID = audioDeviceID(for: device) else {
            print("Audio: could not resolve CoreAudio device"); return
        }

        // Canonical format: 48kHz stereo interleaved Float32
        var fmt = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        let fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        // Input unit (HAL, input-only from USB device)
        var inDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let inComp = AudioComponentFindNext(nil, &inDesc) else { return }
        var inUnit: AudioUnit?
        guard AudioComponentInstanceNew(inComp, &inUnit) == noErr, let inUnit else { return }
        var one: UInt32 = 1, zero: UInt32 = 0
        AudioUnitSetProperty(inUnit, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input, 1, &one, 4)
        AudioUnitSetProperty(inUnit, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output, 0, &zero, 4)
        var dID = devID
        AudioUnitSetProperty(inUnit, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &dID,
                             UInt32(MemoryLayout<AudioDeviceID>.size))
        // Set client-side format on input unit (bus 1, output scope)
        AudioUnitSetProperty(inUnit, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output, 1, &fmt, fmtSize)

        // Output unit (DefaultOutput to speakers)
        var outDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_DefaultOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let outComp = AudioComponentFindNext(nil, &outDesc) else {
            AudioComponentInstanceDispose(inUnit); return
        }
        var outUnit: AudioUnit?
        guard AudioComponentInstanceNew(outComp, &outUnit) == noErr, let outUnit else {
            AudioComponentInstanceDispose(inUnit); return
        }
        // Set client-side format on output unit (bus 0, input scope)
        AudioUnitSetProperty(outUnit, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input, 0, &fmt, fmtSize)

        // Ring buffer: 4096 frames * 2 channels
        audioRingBuffer = AudioRingBuffer(capacity: 4096 * 2)
        audioRenderBuf = .allocate(capacity: 4096 * 2)
        audioInputUnit = inUnit

        // Input callback — called when USB device has new data, pushes to ring buffer
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        var inCb = AURenderCallbackStruct(inputProc: audioInputCallback, inputProcRefCon: refCon)
        AudioUnitSetProperty(inUnit, kAudioOutputUnitProperty_SetInputCallback,
                             kAudioUnitScope_Global, 0, &inCb,
                             UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        // Output callback — called when speakers need data, pulls from ring buffer
        var outCb = AURenderCallbackStruct(inputProc: audioOutputCallback, inputProcRefCon: refCon)
        AudioUnitSetProperty(outUnit, kAudioUnitProperty_SetRenderCallback,
                             kAudioUnitScope_Input, 0, &outCb,
                             UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        AudioUnitInitialize(inUnit)
        AudioUnitInitialize(outUnit)
        AudioOutputUnitStart(inUnit)
        AudioOutputUnitStart(outUnit)
        audioOutputUnit = outUnit
        print("Audio: \(device.localizedName)")
    }

    func removeAudioFromSession() {
        if let out = audioOutputUnit { AudioOutputUnitStop(out); AudioComponentInstanceDispose(out) }
        audioOutputUnit = nil
        if let inp = audioInputUnit { AudioOutputUnitStop(inp); AudioComponentInstanceDispose(inp) }
        audioInputUnit = nil
        audioRingBuffer = nil
        audioRenderBuf?.deallocate()
        audioRenderBuf = nil
        guard let sess = session else { return }
        sess.beginConfiguration()
        if let input = audioInput { sess.removeInput(input) }
        sess.commitConfiguration()
        audioDevice = nil
        audioInput = nil
    }

    func switchAudioDevice(_ device: AVCaptureDevice) {
        guard let sess = session else { return }
        removeAudioFromSession()
        setupAudioDevice(device, in: sess)
        updateAudioToolbarIcon()
    }

    func setupWindow() {
        let f = NSMakeRect(100, 100, Config.windowWidth, Config.windowHeight)
        window = NSWindow(contentRect: f,
            styleMask: [.titled,.closable,.resizable,.miniaturizable],
            backing: .buffered, defer: false)
        window.title = "NanoKVM"
        window.collectionBehavior = .fullScreenPrimary
        window.delegate = self; window.acceptsMouseMovedEvents = true
        window.backgroundColor = .black
        window.contentMinSize = NSSize(width: 480, height: 270)
        window.toolbar = makeToolbar()
        window.toolbarStyle = .unified
        window.contentAspectRatio = NSSize(width: Config.windowWidth, height: Config.windowHeight)
        window.setContentSize(NSSize(width: Config.windowWidth, height: Config.windowHeight))
        videoView = VideoView(frame: f)
        videoView.app = self
        if let sess = session {
            previewLayer = AVCaptureVideoPreviewLayer(session: sess)
            previewLayer!.videoGravity = .resizeAspect
            previewLayer!.frame = videoView.bounds
            previewLayer!.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            previewLayer!.contentsScale = window.backingScaleFactor
            videoView.layer!.addSublayer(previewLayer!)
            applyDisplayFilters()
        }
        window.isOpaque = true
        videoView.layer!.isOpaque = true
        previewLayer?.isOpaque = true
        window.contentView = videoView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(videoView)
        recalcRect()
    }

    func trimRecent(_ values: inout [TimeInterval], now: TimeInterval) {
        let cutoff = now - 1.0
        while let first = values.first, first < cutoff {
            values.removeFirst()
        }
    }

    func recordMouseEvent(kind: String) {
        let now = CFAbsoluteTimeGetCurrent()
        mouseEventCount += 1
        recentMouseEvents.append(now)
        if kind == "move" {
            mouseMoveEventCount += 1
            recentMouseMoves.append(now)
        }
        trimRecent(&recentMouseEvents, now: now)
        trimRecent(&recentMouseMoves, now: now)
    }

    func recordMouseReport() {
        let now = CFAbsoluteTimeGetCurrent()
        mouseReportCount += 1
        recentMouseReports.append(now)
        trimRecent(&recentMouseReports, now: now)
    }

    func setMouseInsideVideo(_ inside: Bool) {
        guard mouseInsideVideo != inside else { return }
        mouseInsideVideo = inside
        syncCursorVisibility()
    }

    func updateMouseInsideVideo(_ viewLoc: NSPoint) {
        let windowLoc = videoView.convert(viewLoc, to: nil)
        guard isWindowPointInsideVideoContent(windowLoc) else {
            leaveVideoInputRegion()
            return
        }
        let inside = pixelToNorm(
            viewLoc.x,
            videoView.bounds.height - viewLoc.y,
            rRect,
            rRectInvW,
            rRectInvH) != nil
        setMouseInsideVideo(inside)
    }

    func videoCursorRect(in view: NSView) -> NSRect {
        var rect = rRect.intersection(view.bounds)
        guard window != nil else { return rect }
        let contentLayoutInView = view.convert(window.contentLayoutRect, from: nil)
        rect = rect.intersection(contentLayoutInView)
        for toolbarWindow in fullscreenToolbarWindows()
            where toolbarWindow.isVisible && toolbarWindow.alphaValue > 0.01 {
            let toolbarInWindow = window.convertFromScreen(toolbarWindow.frame)
            let toolbarInView = view.convert(toolbarInWindow, from: nil)
            let overlap = rect.intersection(toolbarInView)
            guard !overlap.isEmpty,
                  overlap.width >= rect.width * 0.5,
                  overlap.maxY >= rect.maxY - 1 else { continue }
            rect.size.height = max(0, overlap.minY - rect.minY)
        }
        return rect
    }

    func enforceFullscreenToolbarCursor(on candidate: NSWindow? = nil) {
        let candidates = candidate.map { [$0] } ?? fullscreenToolbarWindows()
        for toolbarWindow in candidates where toolbarWindow !== window {
            let className = String(describing: type(of: toolbarWindow))
            guard className.contains("ToolbarFullScreenWindow"),
                  let contentView = toolbarWindow.contentView,
                  !configuredToolbarWindows.contains(toolbarWindow) else { continue }
            toolbarWindow.acceptsMouseMovedEvents = true
            contentView.addCursorRect(contentView.bounds, cursor: .arrow)
            configuredToolbarWindows.add(toolbarWindow)
        }
    }

    func shouldUseTransparentVideoCursor() -> Bool {
        Config.cursorHiddenPreferred &&
            serial.isOpen &&
            window?.isKeyWindow == true &&
            NSApp.isActive
    }

    func syncCursorVisibility() {
        let shouldHide = shouldUseTransparentVideoCursor() && mouseInsideVideo
        cursorActuallyHidden = shouldHide
        window?.invalidateCursorRects(for: videoView)
        if !shouldHide {
            NSCursor.arrow.set()
        }
    }

    func showSystemCursorIfHidden() {
        let wasHidden = cursorActuallyHidden
        cursorActuallyHidden = false
        if wasHidden {
            window?.invalidateCursorRects(for: videoView)
        }
        NSCursor.arrow.set()
        scheduleToolbarCursorRestore()
    }

    func scheduleToolbarCursorRestore() {
        guard !toolbarCursorRestoreScheduled,
              isScreenPointOverFullscreenToolbar(NSEvent.mouseLocation) else { return }
        toolbarCursorRestoreScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.toolbarCursorRestoreScheduled = false
            if self.isScreenPointOverFullscreenToolbar(NSEvent.mouseLocation) {
                NSCursor.arrow.set()
            }
        }
    }

    func applyDisplayFilters() {
        if colorEquals(displayColor, DisplayColor.neutral) {
            previewLayer?.filters = nil
            frozenLayer?.filters = nil
            refreshDebugPanel()
            return
        }
        guard let filter = CIFilter(name: "CIColorControls") else { return }
        filter.setDefaults()
        filter.setValue(displayColor.saturation, forKey: kCIInputSaturationKey)
        filter.setValue(displayColor.brightness - 1.0, forKey: kCIInputBrightnessKey)
        filter.setValue(displayColor.contrast, forKey: kCIInputContrastKey)
        previewLayer?.filters = [filter]
        frozenLayer?.filters = [filter]
        refreshDebugPanel()
    }

    func setDisplayColor(_ color: DisplayColor) {
        displayColor = color
        UserDefaults.standard.set(color.brightness, forKey: "displayBrightness")
        UserDefaults.standard.set(color.contrast, forKey: "displayContrast")
        UserDefaults.standard.set(color.saturation, forKey: "displaySaturation")
        applyDisplayFilters()
    }

    func colorEquals(_ lhs: DisplayColor, _ rhs: DisplayColor) -> Bool {
        abs(lhs.brightness - rhs.brightness) < 0.005 &&
            abs(lhs.contrast - rhs.contrast) < 0.005 &&
            abs(lhs.saturation - rhs.saturation) < 0.005
    }

    func flushMouse() {
        guard serial.isOpen else { return }
        guard !handleFullscreenToolbarAtCurrentMouseLocation() else { return }
        guard mouseInsideVideo else {
            cancelPendingMouseMotion()
            return
        }
        if Config.mouseAbsolute {
            guard let pos = pendingMove else { return }
            serial.sendMouseAbsolute(mouse.build(nx: pos.0, ny: pos.1))
            pendingMove = nil
            recordMouseReport()
        } else {
            if pendingRelDx != 0 || pendingRelDy != 0 {
                let dx = max(-127, min(127, pendingRelDx))
                let dy = max(-127, min(127, pendingRelDy))
                serial.sendMouseRelative(mouse.buildRelative(dx: dx, dy: dy))
                pendingRelDx = 0; pendingRelDy = 0
                recordMouseReport()
            }
        }
    }

    func releaseAll() {
        isPasting = false
        capturedKeyCodes.removeAll()
        capturedModifierStates.removeAll()
        guard serial.isOpen else { return }
        serial.sendKeyboard(kb.releaseAll())
        releaseMouseButtons()
    }

    func recalcRect() {
        guard let cv = window.contentView else { return }
        rRect = calcRenderRect(vw: videoW, vh: videoH, ww: cv.bounds.width, wh: cv.bounds.height)
        rRectInvW = rRect.width > 0 ? 1.0 / rRect.width : 0
        rRectInvH = rRect.height > 0 ? 1.0 / rRect.height : 0
        if videoView != nil {
            window.invalidateCursorRects(for: videoView)
        }
    }

    // MARK: - Window Delegate

    func windowWillStartLiveResize(_ n: Notification) {
        isResizing = true
        releaseAll()
        syncCursorVisibility()
    }
    func windowDidEndLiveResize(_ n: Notification) {
        isResizing = false
        syncCursorVisibility()
    }
    func windowDidResize(_ n: Notification) { recalcRect(); updateMouseLocationFromSystem() }
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposed: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        return [.fullScreen, .autoHideMenuBar, .autoHideToolbar]
    }
    func windowDidEnterFullScreen(_ n: Notification) {
        recalcRect()
        updateMouseLocationFromSystem()
        DispatchQueue.main.async { [weak self] in
            self?.enforceFullscreenToolbarCursor()
        }
    }
    func windowDidExitFullScreen(_ n: Notification) {
        configuredToolbarWindows.removeAllObjects()
        toolbarReturnPosition = nil
        fullscreenToolbarPointerActive = false
        recalcRect()
        updateMouseLocationFromSystem()
    }
    func windowDidChangeBackingProperties(_ n: Notification) {
        showTransitionResumeShield()
        previewLayer?.contentsScale = window.backingScaleFactor
        recalcRect()
        updateMouseLocationFromSystem()
        resumeForegroundVideoAfterShield()
    }
    func windowDidChangeScreen(_ n: Notification) {
        showTransitionResumeShield()
        previewLayer?.contentsScale = window.backingScaleFactor
        recalcRect()
        updateMouseLocationFromSystem()
        resumeForegroundVideoAfterShield()
    }
    func windowDidChangeOcclusionState(_ n: Notification) {
        if !window.occlusionState.contains(.visible) {
            showTransitionResumeShield()
        } else {
            resumeForegroundVideoAfterShield()
        }
        applyVisibilityAwareLivePolicy()
    }
    func windowDidResignKey(_ n: Notification) {
        waitingForForegroundFrame = false
        foregroundResumeFramesNeeded = 0
        inactivePolicyWorkItem?.cancel()
        inactivePolicyWorkItem = nil
        showTransitionResumeShield()
        leaveVideoInputRegion()
        showSystemCursorIfHidden()
        stopMouseFlush()
        releaseAll()
        if let out = audioOutputUnit { AudioOutputUnitStop(out) }
        sessionWatchdog?.cancel()
        sessionWatchdog = nil
        scheduleInactiveWindowVideoPolicy()
    }

    func windowDidBecomeKey(_ n: Notification) {
        inactivePolicyWorkItem?.cancel()
        inactivePolicyWorkItem = nil
        beginMouseInputBarrier(duration: 0.25, waitForButtonsUp: true)
        syncCursorVisibility()
        if serial.isOpen { startMouseFlush() }
        audioRingBuffer?.drain()
        if let out = audioOutputUnit { AudioOutputUnitStart(out) }
        refreshTimer?.invalidate()
        refreshTimer = nil
        isBackgroundRefresh = false
        backgroundRefreshStartedAt = nil
        sessionQueue.async { [weak self] in
            self?.session?.startRunning()
        }
        resumeForegroundVideoAfterShield(forceShield: window.styleMask.contains(.fullScreen))
        sessionWatchdog?.cancel()
        let wd = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sessionWatchdog = nil
            self.enableFrameOutput()
            self.sessionQueue.async {
                self.session?.stopRunning()
                self.session?.startRunning()
            }
        }
        sessionWatchdog = wd
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: wd)
    }

    func scheduleInactiveWindowVideoPolicy() {
        guard !isRecording,
              (backgroundRefreshInterval == Config.backgroundRefreshAdaptive ||
                backgroundRefreshInterval > Config.backgroundRefreshLive),
              window.occlusionState.contains(.visible),
              !window.isMiniaturized else {
            applyInactiveWindowVideoPolicy()
            return
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.inactivePolicyWorkItem = nil
            guard self.window?.isKeyWindow != true else { return }
            self.applyInactiveWindowVideoPolicy()
        }
        inactivePolicyWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Config.inactivePauseGrace, execute: item)
    }

    func backgroundRefresh() {
        guard window?.isKeyWindow != true,
              usesPeriodicBackgroundRefresh(),
              !isBackgroundRefresh else { return }
        isBackgroundRefresh = true
        enableFrameOutput()
        sessionQueue.async { [weak self] in self?.session?.startRunning() }
    }

    func pauseSessionForBackground() {
        lastBackgroundSnapshotAt = Date()
        guard freezeFrame(showStatus: true) else { return }
        sessionQueue.async { [weak self] in self?.session?.stopRunning() }
    }

    func freezeFrame(showStatus: Bool) -> Bool {
        guard let layer = videoView.layer else { return false }
        if frozenLayer != nil {
            updateBackgroundStatusLayer(show: showStatus)
            return true
        }
        guard let snapshot = cgImageFromLatestBuffer() else { return false }
        let frozen = CALayer()
        frozen.frame = layer.bounds
        frozen.contentsScale = window.backingScaleFactor
        frozen.contentsGravity = .resizeAspect
        frozen.backgroundColor = CGColor.black
        frozen.contents = snapshot
        frozen.filters = previewLayer?.filters
        frozen.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.addSublayer(frozen)
        frozenLayer = frozen
        updateBackgroundStatusLayer(show: showStatus)
        return true
    }

    func showTransitionResumeShield() {
        guard window != nil,
              window.styleMask.contains(.fullScreen) ||
                !window.occlusionState.contains(.visible) else { return }
        beginResumeShield()
        lastBackgroundSnapshotAt = Date()
        if !freezeFrame(showStatus: false) {
            enableFrameOutput()
        }
    }

    func beginResumeShield() {
        resumeShieldGeneration += 1
        pendingUnfreezeWorkItem?.cancel()
        pendingUnfreezeWorkItem = nil
        waitingForForegroundFrame = false
        foregroundResumeFramesNeeded = 0
    }

    func resumeForegroundVideoAfterShield(forceShield: Bool = false) {
        guard window != nil,
              NSApp.isActive,
              window.isKeyWindow,
              window.occlusionState.contains(.visible),
              !window.isMiniaturized else { return }
        if forceShield && frozenLayer == nil {
            beginResumeShield()
            _ = freezeFrame(showStatus: false)
        }
        if frozenLayer != nil {
            prepareForegroundResumeOverlay()
        }
        enableFrameOutput()
    }

    func prepareForegroundResumeOverlay() {
        guard let frozen = frozenLayer else { return }
        resumeShieldGeneration += 1
        pendingUnfreezeWorkItem?.cancel()
        pendingUnfreezeWorkItem = nil
        waitingForForegroundFrame = true
        foregroundResumeFramesNeeded = Config.foregroundResumeFramesRequired
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frozen.opacity = 1
        CATransaction.commit()
        backgroundStatusLayer?.removeFromSuperlayer()
        backgroundStatusLayer = nil
    }

    func finishForegroundResume(with image: CGImage?) {
        guard waitingForForegroundFrame else { return }
        if let image, let frozen = frozenLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            frozen.contents = image
            frozen.opacity = 1
            CATransaction.commit()
        }
        foregroundResumeFramesNeeded = max(0, foregroundResumeFramesNeeded - 1)
        guard foregroundResumeFramesNeeded == 0 else { return }
        waitingForForegroundFrame = false
        scheduleUnfreezeForCurrentShield()
    }

    func scheduleUnfreezeForCurrentShield() {
        let generation = resumeShieldGeneration
        pendingUnfreezeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingUnfreezeWorkItem = nil
            guard self.resumeShieldGeneration == generation,
                  !self.waitingForForegroundFrame,
                  NSApp.isActive,
                  self.window?.isKeyWindow == true,
                  self.window?.occlusionState.contains(.visible) == true else { return }
            self.unfreezeFrame()
        }
        pendingUnfreezeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Config.foregroundResumeRevealDelay, execute: item)
    }

    func backgroundRefreshElapsed() -> TimeInterval {
        Date().timeIntervalSince(backgroundRefreshStartedAt ?? Date())
    }

    func usesPeriodicBackgroundRefresh() -> Bool {
        backgroundRefreshInterval == Config.backgroundRefreshAdaptive ||
            backgroundRefreshInterval > Config.backgroundRefreshLive
    }

    func currentBackgroundRefreshInterval() -> TimeInterval {
        guard backgroundRefreshInterval == Config.backgroundRefreshAdaptive else {
            return backgroundRefreshInterval
        }
        let elapsed = backgroundRefreshElapsed()
        if elapsed >= Config.adaptiveRefreshSlowAfter {
            return Config.adaptiveRefreshSlow
        }
        if elapsed >= Config.adaptiveRefreshMediumAfter {
            return Config.adaptiveRefreshMedium
        }
        return Config.adaptiveRefreshFast
    }

    func backgroundRefreshDescription() -> String {
        if backgroundRefreshInterval == Config.backgroundRefreshAdaptive {
            let current = Int(currentBackgroundRefreshInterval())
            return "adaptive \(current)s now (5s for 15m, 30s until 60m, then 60s)"
        }
        return "snapshot every \(Int(backgroundRefreshInterval))s"
    }

    func backgroundStatusText() -> String {
        let timestamp = lastBackgroundSnapshotAt.map {
            DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium)
        } ?? "unknown"
        if backgroundRefreshInterval == Config.backgroundRefreshPaused {
            return "NOT LIVE - paused at \(timestamp)"
        }
        return "NOT LIVE - \(backgroundRefreshDescription()) - updated \(timestamp)"
    }

    func backgroundMonitoringMode() -> String {
        if backgroundRefreshInterval == Config.backgroundRefreshLive {
            return window.occlusionState.contains(.visible) && !window.isMiniaturized
                ? "live while visible"
                : "released while hidden"
        }
        if backgroundRefreshInterval == Config.backgroundRefreshPaused {
            return "paused when inactive"
        }
        if backgroundRefreshInterval == Config.backgroundRefreshAdaptive {
            return "adaptive snapshots: 5s for 15m, 30s until 60m, then 60s"
        }
        return "snapshot every \(Int(backgroundRefreshInterval))s when inactive"
    }

    func shouldShowBackgroundStatus() -> Bool {
        backgroundRefreshInterval == Config.backgroundRefreshPaused ||
            currentBackgroundRefreshInterval() > Config.backgroundStatusThreshold
    }

    func updateBackgroundStatusLayer() {
        updateBackgroundStatusLayer(show: true)
    }

    func updateBackgroundStatusLayer(show: Bool) {
        guard show else {
            clearBackgroundStatusLayer()
            return
        }
        guard shouldShowBackgroundStatus() else {
            clearBackgroundStatusLayer()
            return
        }
        guard frozenLayer != nil, let hostLayer = videoView.layer else { return }
        let status: CATextLayer
        if let existing = backgroundStatusLayer {
            status = existing
        } else {
            status = CATextLayer()
            status.alignmentMode = .center
            status.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
            status.fontSize = 13
            status.foregroundColor = NSColor.white.cgColor
            status.backgroundColor = NSColor.systemRed.withAlphaComponent(0.90).cgColor
            status.cornerRadius = 6
            status.contentsScale = window.backingScaleFactor
            status.autoresizingMask = [.layerMaxXMargin, .layerMinYMargin]
            hostLayer.addSublayer(status)
            backgroundStatusLayer = status
        }
        status.string = backgroundStatusText()
        status.frame = NSRect(
            x: 16,
            y: max(16, hostLayer.bounds.height - 50),
            width: min(430, max(260, hostLayer.bounds.width - 32)),
            height: 32)
    }

    func clearBackgroundStatusLayer() {
        backgroundStatusLayer?.removeFromSuperlayer()
        backgroundStatusLayer = nil
    }

    func unfreezeFrame() {
        guard let frozen = frozenLayer else { return }
        pendingUnfreezeWorkItem?.cancel()
        pendingUnfreezeWorkItem = nil
        frozenLayer = nil
        backgroundStatusLayer?.removeFromSuperlayer()
        backgroundStatusLayer = nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        CATransaction.setCompletionBlock {
            frozen.removeFromSuperlayer()
        }
        frozen.opacity = 0
        CATransaction.commit()
    }

    func enableFrameOutput() {
        frameOutput?.connection(with: .video)?.isEnabled = true
    }
    func disableFrameOutput() {
        frameOutput?.connection(with: .video)?.isEnabled = false
    }

    func shouldKeepFrameOutputEnabled() -> Bool {
        debugWindow?.isVisible == true ||
            isRecording ||
            waitingForForegroundFrame ||
            isBackgroundRefresh
    }

    func startBackgroundRefreshTimer() {
        guard usesPeriodicBackgroundRefresh() else { return }
        refreshTimer?.invalidate()
        let interval = currentBackgroundRefreshInterval()
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.refreshTimer = nil
            self.backgroundRefresh()
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    func applyInactiveWindowVideoPolicy() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        backgroundRefreshStartedAt = Date()
        guard !isRecording, backgroundRefreshInterval != Config.backgroundRefreshLive else {
            unfreezeFrame()
            applyVisibilityAwareLivePolicy()
            return
        }
        pauseSessionForBackground()
        startBackgroundRefreshTimer()
    }

    func applyVisibilityAwareLivePolicy() {
        guard !isRecording, backgroundRefreshInterval == Config.backgroundRefreshLive else { return }
        let isVisible = window.occlusionState.contains(.visible) && !window.isMiniaturized
        sessionQueue.async { [weak self] in
            guard let session = self?.session else { return }
            if isVisible {
                session.startRunning()
            } else {
                session.stopRunning()
            }
        }
    }

    func resetFrameMetrics() {
        actualFrameCount = 0
        actualFrameFps = 0
        droppedFrameEstimate = 0
        lastFramePTS = nil
        frameSampleStartedAt = CFAbsoluteTimeGetCurrent()
        frameSampleCount = 0
    }

    func effectiveTargetFPS() -> Double {
        if let fps = requestedFrameRate.fps { return fps }
        if let device = currentDevice,
           let fps = frameDurationFPS(device.activeVideoMaxFrameDuration) {
            return fps
        }
        let advertised = currentDevice?.activeFormat.videoSupportedFrameRateRanges
            .map { $0.maxFrameRate }.max() ?? 0
        return min(advertised, 60)
    }

    func recordFrameMetrics(_ sampleBuffer: CMSampleBuffer) {
        actualFrameCount += 1
        frameSampleCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - frameSampleStartedAt
        if elapsed >= 1.0 {
            actualFrameFps = Double(frameSampleCount) / elapsed
            frameSampleCount = 0
            frameSampleStartedAt = now
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if let lastFramePTS, pts.isValid, lastFramePTS.isValid {
            let delta = CMTimeGetSeconds(CMTimeSubtract(pts, lastFramePTS))
            let fps = effectiveTargetFPS()
            if delta.isFinite, delta > 0, fps > 0 {
                let expectedFrames = Int((delta * fps).rounded()) - 1
                if expectedFrames > 0 { droppedFrameEstimate += expectedFrames }
            }
        }
        lastFramePTS = pts
    }

    func cgImageFromLatestBuffer() -> CGImage? {
        guard let pb = latestPixelBuffer else { return nil }
        return cgImage(from: pb)
    }

    func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        return cgImage
    }

    func windowWillClose(_ n: Notification) {
        Config.cursorHiddenPreferred = false
        showSystemCursorIfHidden()
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localKeyboardMonitor {
            NSEvent.removeMonitor(localKeyboardMonitor)
            self.localKeyboardMonitor = nil
        }
        stopDebugPanel()
        stopMouseFlush()
        releaseAll(); serial.close()
        if isRecording {
            movieFileOutput?.stopRecording()
            // fileOutput delegate will be called, but we're closing — just wait briefly
            Thread.sleep(forTimeInterval: 0.5)
        }
        session?.stopRunning()
        NSApp.terminate(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { true }
    func applicationDidResignActive(_ notification: Notification) {
        leaveVideoInputRegion()
        beginMouseInputBarrier(duration: 0.35, waitForButtonsUp: true)
        showSystemCursorIfHidden()
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        beginMouseInputBarrier(duration: 0.25, waitForButtonsUp: true)
        syncCursorVisibility()
    }

    // MARK: - Toolbar Setup

    func makeToolbar() -> NSToolbar {
        let tb = NSToolbar(identifier: "MainToolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        return tb
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.video, .display, .audio, .serial, .flexibleSpace, .keyboard, .ctrlAltDel, .mouse, .debug, .flexibleSpace, .record]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.video, .display, .audio, .serial, .keyboard, .ctrlAltDel, .mouse, .debug, .record, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == .ctrlAltDel {
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = shortcutBadgeImage("CAD")
            item.label = "CAD"
            item.paletteLabel = "Ctrl+Alt+Del"
            item.toolTip = "Send Ctrl+Alt+Del"
            item.target = self
            item.action = #selector(sendCtrlAltDel(_:))
            return item
        }

        let item = NSMenuToolbarItem(itemIdentifier: id)
        let menu = NSMenu()
        menu.delegate = self

        switch id {
        case .video:
            item.image = NSImage(systemSymbolName: "video", accessibilityDescription: "Video")
            item.label = "Video"; menu.title = "Video"
            populateVideoMenu(menu)
        case .display:
            item.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Display")
            item.label = "Display"; menu.title = "Display"
            populateDisplayMenu(menu)
        case .audio:
            let iconName = (audioDevice != nil && !audioMuted) ? "speaker.wave.2" : "speaker.slash"
            item.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Audio")
            item.label = "Audio"; menu.title = "Audio"
            populateAudioMenu(menu)
        case .serial:
            item.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Serial")
            item.label = "Serial"; menu.title = "Serial"
            populateSerialMenu(menu)
        case .keyboard:
            item.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyboard")
            item.label = "Keyboard"; menu.title = "Keyboard"
            populateKeyboardMenu(menu)
        case .mouse:
            item.image = NSImage(systemSymbolName: "cursorarrow", accessibilityDescription: "Mouse")
            item.label = "Mouse"; menu.title = "Mouse"
            populateMouseMenu(menu)
        case .record:
            item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Record")
            item.label = "Record"; menu.title = "Record"
            populateRecordMenu(menu)
        case .debug:
            item.image = NSImage(systemSymbolName: "ladybug", accessibilityDescription: "Debug")
            item.label = "Debug"; menu.title = "Debug"
            populateDebugMenu(menu)
        default: return nil
        }

        item.menu = menu
        return item
    }

    // MARK: - Menu Delegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        switch menu.title {
        case "Video":    populateVideoMenu(menu)
        case "Display":  populateDisplayMenu(menu)
        case "Audio":    populateAudioMenu(menu)
        case "Serial":   populateSerialMenu(menu)
        case "Keyboard": populateKeyboardMenu(menu)
        case "Mouse":    populateMouseMenu(menu)
        case "Record":   populateRecordMenu(menu)
        case "Debug":    populateDebugMenu(menu)
        default: break
        }
    }

    func addMenuGuard(_ menu: NSMenu) {
        let dummy = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        dummy.isHidden = true
        menu.addItem(dummy)
    }

    @discardableResult
    func menuItem(_ menu: NSMenu, _ title: String, _ action: Selector,
                  checked: Bool = false, enabled: Bool = true,
                  icon: String? = nil, obj: Any? = nil, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let obj { item.representedObject = obj }
        if checked { item.state = .on }
        item.isEnabled = enabled
        if tag != 0 { item.tag = tag }
        if let icon { item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) }
        menu.addItem(item)
        return item
    }

    func submenu(_ menu: NSMenu, _ title: String, icon: String? = nil, _ build: (NSMenu) -> Void) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let icon { item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) }
        let sub = NSMenu()
        build(sub)
        item.submenu = sub
        menu.addItem(item)
    }

    func sliderMenuItem(_ menu: NSMenu, title: String, value: Double, min: Double, max: Double,
                        action: Selector) {
        let item = NSMenuItem()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 44))
        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: 12, y: 24, width: 130, height: 18)
        label.font = .systemFont(ofSize: 12)
        let valueLabel = NSTextField(labelWithString: "\(Int((value * 100).rounded()))%")
        valueLabel.frame = NSRect(x: 200, y: 24, width: 48, height: 18)
        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let slider = NSSlider(value: value, minValue: min, maxValue: max, target: self, action: action)
        slider.frame = NSRect(x: 12, y: 4, width: 236, height: 20)
        slider.numberOfTickMarks = 0
        slider.isContinuous = true
        view.addSubview(label)
        view.addSubview(valueLabel)
        view.addSubview(slider)
        item.view = view
        menu.addItem(item)
    }

    func populateVideoMenu(_ menu: NSMenu) {
        addMenuGuard(menu)
        let devices = findCaptureDevices()
        for dev in devices {
            menuItem(menu, dev.localizedName, #selector(videoDeviceSelected(_:)),
                     checked: dev.uniqueID == currentDevice?.uniqueID, obj: dev)
        }
        guard let device = currentDevice else { return }
        menu.addItem(.separator())
        let activeDims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let activeSummary = NSMenuItem(
            title: "Active: \(activeDims.width)\u{00D7}\(activeDims.height)  \(frameRateText(activeFrameRate(for: device)))  \(fourCC(device.activeFormat))",
            action: nil,
            keyEquivalent: "")
        activeSummary.isEnabled = false
        menu.addItem(activeSummary)
        menu.addItem(.separator())
        var bestForRes: [String: AVCaptureDevice.Format] = [:]
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let key = "\(dims.width)x\(dims.height)"
            let has5fps = format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 5 }
            guard has5fps else { continue }
            if let existing = bestForRes[key] {
                if formatScore(format) > formatScore(existing) { bestForRes[key] = format }
            } else { bestForRes[key] = format }
        }
        var entries: [(w: Int32, h: Int32, format: AVCaptureDevice.Format)] = []
        for (_, format) in bestForRes {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            entries.append((dims.width, dims.height, format))
        }
        entries.sort { ($0.w * $0.h) > ($1.w * $1.h) }
        for entry in entries {
            menuItem(menu, "\(entry.w)\u{00D7}\(entry.h)", #selector(formatSelected(_:)),
                     checked: entry.w == activeDims.width && entry.h == activeDims.height, obj: entry.format)
        }
        menu.addItem(.separator())
        submenu(menu, "Frame rate", icon: "speedometer") { sub in
            for choice in VideoFrameRateChoice.allCases {
                let supported = choice.fps.map { formatSupports(device.activeFormat, fps: $0) } ?? true
                menuItem(sub, choice.title, #selector(frameRateSelected(_:)),
                         checked: choice == requestedFrameRate,
                         enabled: supported || choice == .auto,
                         obj: choice.storageValue)
            }
        }
        submenu(menu, "Inactive window refresh") { sub in
            for (title, interval) in [
                ("Adaptive: 5s for 15m, then 30s / 60s (default)", Config.backgroundRefreshAdaptive),
                ("Live while visible", 0.0),
                ("Every 1 second", 1.0),
                ("Every 5 seconds", 5.0),
                ("Every 10 seconds", 10.0),
                ("Every 30 seconds", 30.0),
                ("Every 60 seconds", 60.0),
                ("Every 2 minutes", 120.0),
                ("Every 5 minutes", 300.0),
                ("Paused", -1.0)
            ] {
                menuItem(sub, title, #selector(setBackgroundRefresh(_:)),
                         checked: Int(interval) == Int(backgroundRefreshInterval), tag: Int(interval))
            }
        }
    }

    func populateDisplayMenu(_ menu: NSMenu) {
        addMenuGuard(menu)
        sliderMenuItem(menu, title: "Brightness", value: displayColor.brightness,
                       min: 0.80, max: 1.25, action: #selector(brightnessChanged(_:)))
        sliderMenuItem(menu, title: "Contrast", value: displayColor.contrast,
                       min: 0.80, max: 1.35, action: #selector(contrastChanged(_:)))
        sliderMenuItem(menu, title: "Saturation", value: displayColor.saturation,
                       min: 0.70, max: 1.45, action: #selector(saturationChanged(_:)))
        menu.addItem(.separator())
        menuItem(menu, "Recommended 101 / 112 / 109", #selector(setRecommendedColor(_:)),
                 checked: colorEquals(displayColor, DisplayColor.recommended), icon: "checkmark.circle")
        menuItem(menu, "Neutral 100 / 100 / 100 (lower GPU use)", #selector(setNeutralColor(_:)),
                 checked: colorEquals(displayColor, DisplayColor.neutral))
        menuItem(menu, "Range expand 100 / 115 / 108", #selector(setRangeExpandColor(_:)),
                 checked: colorEquals(displayColor, DisplayColor.rangeExpand))
    }

    func populateSerialMenu(_ menu: NSMenu) {
        addMenuGuard(menu)
        let ports = findSerialPorts()
        for port in ports {
            menuItem(menu, port, #selector(serialPortSelected(_:)),
                     checked: port == currentSerialPath, obj: port)
        }
        if ports.isEmpty {
            let item = NSMenuItem(title: "No USB serial devices", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menuItem(menu, "Disconnect", #selector(disconnectSerial(_:)), enabled: serial.isOpen)
    }

    func populateKeyboardMenu(_ menu: NSMenu) {
        addMenuGuard(menu)
        menuItem(menu, "Paste", #selector(pasteClipboard(_:)), icon: "doc.on.clipboard")
        menuItem(menu, "Capture Host Shortcuts in Full Screen",
                 #selector(toggleKeyboardCapture(_:)),
                 checked: Config.keyboardCaptureHostShortcuts,
                 icon: "keyboard.badge.ellipsis")
        menu.addItem(.separator())
        submenu(menu, "Keyboard", icon: "keyboard") { sub in
            for (title, sel) in [
                ("Ctrl+Alt+Del", #selector(sendCtrlAltDel(_:))),
                ("Win+Tab",      #selector(sendWinTab(_:))),
                ("Alt+F4",       #selector(sendAltF4(_:))),
                ("Ctrl+Esc",     #selector(sendCtrlEsc(_:))),
            ] as [(String, Selector)] {
                menuItem(sub, title, sel)
            }
            sub.addItem(.separator())
            menuItem(sub, "Release All Keys", #selector(sendReleaseAll(_:)))
        }
        submenu(menu, "Shortcuts", icon: "command") { sub in
            for title in ["Cmd+F  Fullscreen", "Cmd+Tab is reserved by macOS", "Use Option+Tab for Windows Alt+Tab"] {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                sub.addItem(item)
            }
        }
    }

    func populateMouseMenu(_ menu: NSMenu) {
        addMenuGuard(menu)
        submenu(menu, "Cursor", icon: "cursorarrow") { sub in
            menuItem(sub, "Show Cursor", #selector(showCursor(_:)), checked: !Config.cursorHiddenPreferred)
            menuItem(sub, "Hide Cursor in Video", #selector(hideCursor(_:)), checked: Config.cursorHiddenPreferred)
        }
        submenu(menu, "Mouse mode", icon: "cursorarrow.motionlines") { sub in
            menuItem(sub, "Absolute", #selector(setMouseAbsolute(_:)), checked: Config.mouseAbsolute)
            menuItem(sub, "Relative", #selector(setMouseRelative(_:)), checked: !Config.mouseAbsolute)
        }
        submenu(menu, "Wheel direction", icon: "arrow.up.arrow.down") { sub in
            menuItem(sub, "Natural", #selector(setScrollNatural(_:)), checked: Config.scrollDirection == -1)
            menuItem(sub, "Inverted", #selector(setScrollInverted(_:)), checked: Config.scrollDirection == 1)
        }
        submenu(menu, "Wheel speed", icon: "speedometer") { sub in
            for (title, val) in [("Slow", 0.003), ("Normal", 0.01), ("Fast", 0.025), ("Very Fast", 0.05)] as [(String, Double)] {
                menuItem(sub, title, #selector(setScrollSpeed(_:)),
                         checked: Config.scrollSpeed == val, tag: Int(val * 10000))
            }
        }
        menu.addItem(.separator())
        menuItem(menu, "Mouse Jiggler", #selector(toggleJiggler(_:)),
                 checked: isJiggling, enabled: serial.isOpen, icon: "sparkle")
    }

    func populateRecordMenu(_ menu: NSMenu) {
        addMenuGuard(menu)
        menuItem(menu, "Screenshot", #selector(takeScreenshot(_:)),
                 enabled: latestPixelBuffer != nil || session != nil, icon: "camera")
        submenu(menu, "Screenshot format", icon: "photo") { sub in
            for (title, fmt) in [("PNG", ScreenshotFormat.png), ("JPEG", .jpeg), ("HEIC", .heic)] as [(String, ScreenshotFormat)] {
                menuItem(sub, title, #selector(setScreenshotFormat(_:)),
                         checked: screenshotFormat == fmt, obj: fmt.rawValue)
            }
        }
        if screenshotFormat != .png {
            submenu(menu, "Screenshot quality", icon: "slider.horizontal.3") { sub in
                for (title, val) in [("Low (50%)", 0.5), ("Medium (70%)", 0.7), ("High (85%)", 0.85),
                                      ("Very High (95%)", 0.95), ("Maximum (100%)", 1.0)] as [(String, Double)] {
                    menuItem(sub, title, #selector(setScreenshotQuality(_:)),
                             checked: Int(screenshotQuality * 100) == Int(val * 100), tag: Int(val * 100))
                }
            }
        }
        menu.addItem(.separator())
        menuItem(menu, isRecording ? "Stop Recording" : "Start Recording",
                 #selector(toggleRecording(_:)),
                 icon: isRecording ? "stop.circle" : "record.circle")
        submenu(menu, "Recording codec", icon: "film") { sub in
            for (title, codec) in [("H.264", AVVideoCodecType.h264), ("H.265 (HEVC)", .hevc)] as [(String, AVVideoCodecType)] {
                menuItem(sub, title, #selector(setRecordingCodec(_:)),
                         checked: recordingCodec == codec, enabled: !isRecording, obj: codec.rawValue)
            }
        }
    }

    func populateAudioMenu(_ menu: NSMenu) {
        addMenuGuard(menu)
        if audioDevice == nil,
           let videoDevice = currentDevice,
           let matchingAudio = findMatchingAudioDevice(for: videoDevice) {
            menuItem(menu, "Enable Matching Audio", #selector(enableMatchingAudio(_:)),
                     enabled: !isRecording, icon: "speaker.wave.2", obj: matchingAudio)
            menu.addItem(.separator())
        }
        menuItem(menu, audioMuted ? "Unmute Output" : "Mute Output", #selector(toggleAudioMute(_:)),
                 enabled: audioDevice != nil,
                 icon: audioMuted ? "speaker.slash" : "speaker.wave.2")
        menu.addItem(.separator())
        let audioDevices = findAudioCaptureDevices()
        if audioDevices.isEmpty {
            let item = NSMenuItem(title: "No audio input devices", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for dev in audioDevices {
                menuItem(menu, dev.localizedName, #selector(audioDeviceSelected(_:)),
                         checked: dev.uniqueID == audioDevice?.uniqueID,
                         enabled: !isRecording, obj: dev)
            }
        }
        menu.addItem(.separator())
        menuItem(menu, "Stop Audio Capture", #selector(disconnectAudio(_:)),
                 enabled: audioDevice != nil && !isRecording)
    }

    func populateDebugMenu(_ menu: NSMenu) {
        addMenuGuard(menu)
        menuItem(menu, debugWindow?.isVisible == true ? "Hide Debug Panel" : "Show Debug Panel",
                 #selector(toggleDebugPanel(_:)), icon: "text.magnifyingglass")
        menuItem(menu, "Copy Diagnostics JSON", #selector(copyDiagnosticsJSON(_:)), icon: "doc.on.doc")
        menuItem(menu, "Refresh GET_INFO", #selector(refreshInfoFromMenu(_:)),
                 enabled: serial.isOpen, icon: "arrow.clockwise")
    }

    // MARK: - Debug / Diagnostics

    func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    func round3(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }

    func requestDeviceInfo(force: Bool = false) {
        guard serial.isOpen else { return }
        let now = Date()
        if !force, let lastInfoRequestAt,
           now.timeIntervalSince(lastInfoRequestAt) < 1.5 {
            return
        }
        lastInfoRequestAt = now
        serial.getInfo { [weak self] info in
            guard let self else { return }
            self.lastInfoRaw = info
            self.lastInfoUpdatedAt = Date()
            if let info {
                print("NanoKVM: " + byteHex(info))
            }
            self.refreshDebugPanel()
        }
    }

    func videoDiagnostics() -> [String: Any] {
        guard let device = currentDevice else { return ["state": "not connected"] }
        let format = device.activeFormat
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return [
            "device": device.localizedName,
            "uniqueID": device.uniqueID,
            "manufacturer": device.manufacturer,
            "resolution": "\(dims.width)x\(dims.height)",
            "fourCC": fourCC(format),
            "requestedFrameRate": requestedFrameRate.title,
            "activeMinFPS": frameDurationFPS(device.activeVideoMinFrameDuration).map(round2) ?? "auto",
            "activeMaxFPS": frameDurationFPS(device.activeVideoMaxFrameDuration).map(round2) ?? "auto",
            "actualFPS": round2(actualFrameFps),
            "frameSamples": actualFrameCount,
            "droppedFrameEstimate": droppedFrameEstimate,
            "sessionRunning": session?.isRunning ?? false,
            "frameOutputEnabled": frameOutput?.connection(with: .video)?.isEnabled ?? false,
            "supportedFrameRates": formatFrameRates(format),
            "colorPrimaries": formatExtensionValue(format, kCMFormatDescriptionExtension_ColorPrimaries),
            "transferFunction": formatExtensionValue(format, kCMFormatDescriptionExtension_TransferFunction),
            "yCbCrMatrix": formatExtensionValue(format, kCMFormatDescriptionExtension_YCbCrMatrix),
            "fullRangeVideo": formatExtensionValue(format, kCMFormatDescriptionExtension_FullRangeVideo)
        ]
    }

    func serialDiagnostics() -> [String: Any] {
        let metrics = serial.metrics()
        var result: [String: Any] = [
            "isOpen": serial.isOpen,
            "path": currentSerialPath ?? "",
            "writeCount": metrics.writeCount,
            "errorCount": metrics.errorCount,
            "lastWriteMs": round3(metrics.lastWriteMs),
            "averageWriteMs": round3(metrics.averageWriteMs),
            "maxWriteMs": round3(metrics.maxWriteMs),
            "lastWriteAt": compactDate(metrics.lastWriteAt),
            "lastError": metrics.lastError,
            "getInfoRaw": byteHex(lastInfoRaw),
            "getInfoUpdatedAt": compactDate(lastInfoUpdatedAt)
        ]
        if let info = parseNanoKVMInfo(lastInfoRaw) {
            result["chipVersion"] = info.chipVersion
            result["targetConnected"] = info.isConnected
            result["numLock"] = info.numLock
            result["capsLock"] = info.capsLock
            result["scrollLock"] = info.scrollLock
        }
        return result
    }

    func mouseDiagnostics() -> [String: Any] {
        let now = CFAbsoluteTimeGetCurrent()
        trimRecent(&recentMouseEvents, now: now)
        trimRecent(&recentMouseMoves, now: now)
        trimRecent(&recentMouseReports, now: now)
        return [
            "mode": Config.mouseAbsolute ? "absolute" : "relative",
            "cursorHiddenPreferred": Config.cursorHiddenPreferred,
            "cursorActuallyHidden": cursorActuallyHidden,
            "keyboardCaptureHostShortcuts": Config.keyboardCaptureHostShortcuts,
            "insideVideo": mouseInsideVideo,
            "lastPosition": ["x": round3(lastPos.0), "y": round3(lastPos.1)],
            "eventCount": mouseEventCount,
            "moveEventCount": mouseMoveEventCount,
            "reportCount": mouseReportCount,
            "eventsPerSecond": recentMouseEvents.count,
            "movesPerSecond": recentMouseMoves.count,
            "reportsPerSecond": recentMouseReports.count
        ]
    }

    func diagnosticsPayload() -> [String: Any] {
        [
            "host": [
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "architecture": architectureName(),
                "app": "NanoKVM native macOS",
                "collectedAt": compactDate(Date())
            ],
            "video": videoDiagnostics(),
            "display": [
                "brightness": round2(displayColor.brightness),
                "contrast": round2(displayColor.contrast),
                "saturation": round2(displayColor.saturation),
                "previewFilter": "CIColorControls"
            ],
            "serial": serialDiagnostics(),
            "mouse": mouseDiagnostics(),
            "window": [
                "screen": window.screen?.localizedName ?? "",
                "backingScaleFactor": window.backingScaleFactor,
                "isKey": window.isKeyWindow,
                "isVisible": window.occlusionState.contains(.visible) && !window.isMiniaturized,
                "backgroundMonitoring": backgroundMonitoringMode(),
                "renderRect": [
                    "x": round2(rRect.origin.x),
                    "y": round2(rRect.origin.y),
                    "width": round2(rRect.width),
                    "height": round2(rRect.height)
                ]
            ]
        ]
    }

    func diagnosticsJSONString() -> String {
        let payload = diagnosticsPayload()
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    func diagnosticsText() -> String {
        let video = videoDiagnostics()
        let serialInfo = parseNanoKVMInfo(lastInfoRaw)
        let serialStats = serial.metrics()
        let mouse = mouseDiagnostics()
        var lines: [String] = []
        func add(_ label: String, _ value: Any?) {
            guard let value else { return }
            let text = String(describing: value)
            guard !text.isEmpty, text != "0x0" else { return }
            let padding = String(repeating: " ", count: max(1, 22 - label.count))
            lines.append("\(label)\(padding)\(text)")
        }
        func section(_ title: String) {
            if !lines.isEmpty { lines.append("") }
            lines.append("== \(title) ==")
        }

        section("Video")
        add("Device", video["device"])
        add("Mode", "\(video["resolution"] ?? "")  \(video["fourCC"] ?? "")")
        add("Requested FPS", video["requestedFrameRate"])
        add("Active Min/Max FPS", "\(video["activeMinFPS"] ?? "") / \(video["activeMaxFPS"] ?? "")")
        add("Actual FPS", video["actualFPS"])
        add("Dropped estimate", video["droppedFrameEstimate"])
        add("Session running", video["sessionRunning"])
        add("Background monitoring", backgroundMonitoringMode())
        add("Color primaries", video["colorPrimaries"])
        add("Transfer function", video["transferFunction"])
        add("YCbCr matrix", video["yCbCrMatrix"])
        add("Full range", video["fullRangeVideo"])

        section("Display")
        add("Brightness", "\(Int((displayColor.brightness * 100).rounded()))%")
        add("Contrast", "\(Int((displayColor.contrast * 100).rounded()))%")
        add("Saturation", "\(Int((displayColor.saturation * 100).rounded()))%")
        add("Screen", window.screen?.localizedName ?? "")

        section("Serial")
        add("Port", currentSerialPath)
        add("Open", serial.isOpen)
        if let serialInfo {
            add("Chip", serialInfo.chipVersion)
            add("Target connected", serialInfo.isConnected)
            add("Locks", "Num \(serialInfo.numLock ? "on" : "off") / Caps \(serialInfo.capsLock ? "on" : "off") / Scroll \(serialInfo.scrollLock ? "on" : "off")")
        }
        add("GET_INFO raw", byteHex(lastInfoRaw))
        add("Writes", serialStats.writeCount)
        add("Latency", "\(round3(serialStats.averageWriteMs)) ms avg / \(round3(serialStats.maxWriteMs)) ms max")

        section("Mouse")
        add("Mode", mouse["mode"])
        add("Cursor", "preferred \(Config.cursorHiddenPreferred), actual \(cursorActuallyHidden), inside video \(mouseInsideVideo)")
        add("Keyboard capture", Config.keyboardCaptureHostShortcuts)
        add("Events/sec", mouse["eventsPerSecond"])
        add("Moves/sec", mouse["movesPerSecond"])
        add("Reports/sec", mouse["reportsPerSecond"])

        return lines.joined(separator: "\n")
    }

    func showDebugPanel() {
        if let debugWindow {
            debugWindow.orderFront(nil)
            refreshDebugPanel()
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 140, y: 140, width: 560, height: 520),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false)
        panel.title = "NanoKVM Debug"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false

        let scrollView = NSScrollView(frame: panel.contentView?.bounds ?? .zero)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView
        panel.contentView = scrollView

        debugWindow = panel
        debugTextView = textView
        debugCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main) { [weak self] _ in
                self?.stopDebugPanel()
            }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.requestDeviceInfo()
            self?.refreshDebugPanel()
        }
        RunLoop.main.add(timer, forMode: .common)
        debugTimer = timer
        resetFrameMetrics()
        enableFrameOutput()
        requestDeviceInfo(force: true)
        refreshDebugPanel()
        panel.orderFront(nil)
    }

    func stopDebugPanel() {
        debugTimer?.invalidate()
        debugTimer = nil
        if let debugCloseObserver {
            NotificationCenter.default.removeObserver(debugCloseObserver)
            self.debugCloseObserver = nil
        }
        debugTextView = nil
        debugWindow = nil
        if !isBackgroundRefresh {
            disableFrameOutput()
        }
    }

    func refreshDebugPanel() {
        guard debugWindow?.isVisible == true else { return }
        debugTextView?.string = diagnosticsText()
    }

    @objc func toggleDebugPanel(_ sender: Any?) {
        if let debugWindow, debugWindow.isVisible {
            debugWindow.close()
        } else {
            showDebugPanel()
        }
    }

    @objc func copyDiagnosticsJSON(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(diagnosticsJSONString(), forType: .string)
    }

    @objc func refreshInfoFromMenu(_ sender: Any?) {
        requestDeviceInfo(force: true)
    }

    // MARK: - Audio Actions

    @objc func enableMatchingAudio(_ sender: NSMenuItem) {
        if let dev = sender.representedObject as? AVCaptureDevice {
            switchAudioDevice(dev)
        } else if let videoDevice = currentDevice,
                  let dev = findMatchingAudioDevice(for: videoDevice) {
            switchAudioDevice(dev)
        }
    }

    @objc func toggleAudioMute(_ sender: Any?) {
        audioMuted.toggle()
        updateAudioToolbarIcon()
    }

    @objc func audioDeviceSelected(_ sender: NSMenuItem) {
        guard let dev = sender.representedObject as? AVCaptureDevice else { return }
        switchAudioDevice(dev)
    }

    @objc func disconnectAudio(_ sender: Any?) {
        removeAudioFromSession()
        audioMuted = false
        updateAudioToolbarIcon()
        print("Audio disconnected")
    }

    func updateAudioToolbarIcon() {
        guard let items = window?.toolbar?.items else { return }
        for item in items where item.itemIdentifier == .audio {
            let iconName = (audioDevice != nil && !audioMuted) ? "speaker.wave.2" : "speaker.slash"
            item.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Audio")
        }
    }

    // MARK: - Video Actions

    @objc func videoDeviceSelected(_ sender: NSMenuItem) {
        guard let dev = sender.representedObject as? AVCaptureDevice else { return }
        switchCaptureDevice(dev)
    }

    func switchCaptureDevice(_ device: AVCaptureDevice) {
        guard let sess = session, let oldInput = currentInput else { return }
        guard let newInput = try? AVCaptureDeviceInput(device: device) else { return }
        sess.beginConfiguration()
        sess.removeInput(oldInput)
        if sess.canAddInput(newInput) { sess.addInput(newInput) }
        sess.commitConfiguration()
        currentDevice = device; currentInput = newInput
        selectInitialFormat(for: device)
        recalcRect()
        print("Switched to: \(device.localizedName) (\(videoW)x\(videoH))")

        // Keep audio disabled by default. If the user already enabled audio, follow the new video device.
        if audioDevice != nil, let audioDev = findMatchingAudioDevice(for: device) {
            switchAudioDevice(audioDev)
        }
    }

    @objc func formatSelected(_ sender: NSMenuItem) {
        guard let format = sender.representedObject as? AVCaptureDevice.Format,
              let device = currentDevice else { return }
        applyFormat(format, to: device)
        recalcRect()
    }

    @objc func frameRateSelected(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let device = currentDevice else { return }
        requestedFrameRate = VideoFrameRateChoice(rawValue: rawValue)
        UserDefaults.standard.set(requestedFrameRate.storageValue, forKey: "videoFrameRate")
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        if let replacement = bestFormat(for: device, width: Int(dims.width), height: Int(dims.height)) {
            applyFormat(replacement, to: device, save: false)
        } else {
            applyFrameRate(to: device)
            resetFrameMetrics()
        }
        enableFrameOutput()
        refreshDebugPanel()
    }

    @objc func setBackgroundRefresh(_ sender: NSMenuItem) {
        backgroundRefreshInterval = TimeInterval(sender.tag)
        UserDefaults.standard.set(backgroundRefreshInterval, forKey: "backgroundRefresh")
        UserDefaults.standard.set(
            Config.backgroundRefreshPolicyVersion,
            forKey: "backgroundRefreshPolicyVersion")
        refreshTimer?.invalidate()
        refreshTimer = nil
        isBackgroundRefresh = false
        backgroundRefreshStartedAt = nil
        if window.isKeyWindow {
            unfreezeFrame()
            sessionQueue.async { [weak self] in self?.session?.startRunning() }
        } else {
            applyInactiveWindowVideoPolicy()
        }
    }

    // MARK: - Display Actions

    @objc func brightnessChanged(_ sender: NSSlider) {
        setDisplayColor(DisplayColor(
            brightness: sender.doubleValue,
            contrast: displayColor.contrast,
            saturation: displayColor.saturation))
    }

    @objc func contrastChanged(_ sender: NSSlider) {
        setDisplayColor(DisplayColor(
            brightness: displayColor.brightness,
            contrast: sender.doubleValue,
            saturation: displayColor.saturation))
    }

    @objc func saturationChanged(_ sender: NSSlider) {
        setDisplayColor(DisplayColor(
            brightness: displayColor.brightness,
            contrast: displayColor.contrast,
            saturation: sender.doubleValue))
    }

    @objc func setRecommendedColor(_ sender: Any?) { setDisplayColor(.recommended) }
    @objc func setNeutralColor(_ sender: Any?) { setDisplayColor(.neutral) }
    @objc func setRangeExpandColor(_ sender: Any?) { setDisplayColor(.rangeExpand) }

    // MARK: - Serial Actions

    @objc func serialPortSelected(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        stopMouseFlush()
        serial.close()
        syncCursorVisibility()
        if serial.open(path: path) {
            currentSerialPath = path
            startMouseFlush()
            syncCursorVisibility()
            print("Serial: " + path)
            requestDeviceInfo()
        } else {
            currentSerialPath = nil
            print("Failed to open " + path)
        }
    }

    @objc func disconnectSerial(_ sender: Any?) {
        stopMouseFlush()
        serial.close()
        currentSerialPath = nil
        lastInfoRaw = nil
        lastInfoUpdatedAt = nil
        syncCursorVisibility()
        print("Serial disconnected")
    }

    // MARK: - Keyboard Actions

    @objc func pasteClipboard(_ sender: Any?) {
        guard serial.isOpen, !isPasting else { return }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        isPasting = true
        typeNextChar(Array(text), index: 0)
    }

    private func typeNextChar(_ chars: [Character], index: Int) {
        guard isPasting, index < chars.count else { isPasting = false; return }
        let ch = chars[index]
        if ch == "\n" || ch == "\r" {
            serial.sendKeyboard(kb.keyDown(0x28))
            serial.sendKeyboard(kb.keyUp(0x28))
        } else if ch == "\t" {
            serial.sendKeyboard(kb.keyDown(0x2B))
            serial.sendKeyboard(kb.keyUp(0x2B))
        } else if let (hid, shift) = asciiToHID[ch] {
            if shift { serial.sendKeyboard(kb.keyDown(0xE1)) }
            serial.sendKeyboard(kb.keyDown(hid))
            serial.sendKeyboard(kb.keyUp(hid))
            if shift { serial.sendKeyboard(kb.keyUp(0xE1)) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.typeNextChar(chars, index: index + 1)
        }
    }

    private func sendShortcut(mods: [UInt8], key: UInt8) {
        guard serial.isOpen else { return }
        for m in mods { serial.sendKeyboard(kb.keyDown(m)) }
        serial.sendKeyboard(kb.keyDown(key))
        serial.sendKeyboard(kb.keyUp(key))
        for m in mods.reversed() { serial.sendKeyboard(kb.keyUp(m)) }
    }

    @objc func sendCtrlAltDel(_ sender: Any?) {
        sendShortcut(mods: [0xE0, 0xE2], key: 0x4C) // LCtrl+LAlt+Delete
    }

    @objc func sendWinTab(_ sender: Any?) {
        sendShortcut(mods: [0xE3], key: 0x2B) // LGUI+Tab
    }

    @objc func sendAltF4(_ sender: Any?) {
        sendShortcut(mods: [0xE2], key: 0x3D) // LAlt+F4
    }

    @objc func sendCtrlEsc(_ sender: Any?) {
        sendShortcut(mods: [0xE0], key: 0x29) // LCtrl+Escape
    }

    @objc func sendReleaseAll(_ sender: Any?) {
        releaseAll()
    }

    @objc func toggleKeyboardCapture(_ sender: Any?) {
        Config.keyboardCaptureHostShortcuts.toggle()
        UserDefaults.standard.set(
            Config.keyboardCaptureHostShortcuts,
            forKey: "keyboardCaptureHostShortcuts")
        if !Config.keyboardCaptureHostShortcuts {
            releaseAll()
        }
    }

    // MARK: - Mouse Actions

    @objc func showCursor(_ sender: Any?) {
        Config.cursorHiddenPreferred = false
        UserDefaults.standard.set(Config.cursorHiddenPreferred, forKey: "cursorHiddenPreferred")
        syncCursorVisibility()
    }

    @objc func hideCursor(_ sender: Any?) {
        Config.cursorHiddenPreferred = true
        UserDefaults.standard.set(Config.cursorHiddenPreferred, forKey: "cursorHiddenPreferred")
        syncCursorVisibility()
    }

    @objc func setMouseAbsolute(_ sender: Any?) {
        Config.mouseAbsolute = true
        UserDefaults.standard.set(Config.mouseAbsolute, forKey: "mouseAbsolute")
    }

    @objc func setMouseRelative(_ sender: Any?) {
        Config.mouseAbsolute = false
        UserDefaults.standard.set(Config.mouseAbsolute, forKey: "mouseAbsolute")
    }

    @objc func setScrollNatural(_ sender: Any?) {
        Config.scrollDirection = -1
        UserDefaults.standard.set(Config.scrollDirection, forKey: "scrollDirection")
    }

    @objc func setScrollInverted(_ sender: Any?) {
        Config.scrollDirection = 1
        UserDefaults.standard.set(Config.scrollDirection, forKey: "scrollDirection")
    }

    @objc func setScrollSpeed(_ sender: NSMenuItem) {
        Config.scrollSpeed = Double(sender.tag) / 10000.0
        UserDefaults.standard.set(Config.scrollSpeed, forKey: "scrollSpeed")
    }

    @objc func toggleJiggler(_ sender: Any?) {
        if isJiggling {
            jigglerTimer?.invalidate()
            jigglerTimer = nil
            isJiggling = false
            print("Jiggler stopped")
        } else {
            isJiggling = true
            let t = Timer(timeInterval: 30.0, repeats: true) {
                [weak self] _ in
                guard let self = self, self.serial.isOpen else { return }
                let nx = self.lastPos.0, ny = self.lastPos.1
                let jig = (nx > 0.5) ? -0.001 : 0.001
                self.serial.sendMouseAbsolute(self.mouse.build(nx: nx + jig, ny: ny))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.serial.sendMouseAbsolute(self.mouse.build(nx: nx, ny: ny))
                }
            }
            RunLoop.main.add(t, forMode: .common)
            jigglerTimer = t
            print("Jiggler started (30s interval)")
        }
    }

    // MARK: - Screenshot Actions

    @objc func takeScreenshot(_ sender: Any?) {
        guard let cgImage = cgImageFromLatestBuffer() else { return }
        let ext: String
        let utType: UTType
        switch screenshotFormat {
        case .png:  ext = "png";  utType = .png
        case .jpeg: ext = "jpg";  utType = .jpeg
        case .heic: ext = "heic"; utType = .heic
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [utType]
        panel.nameFieldStringValue = "NanoKVM-Screenshot.\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, utType.identifier as CFString, 1, nil) else {
            print("Failed to create image destination"); return
        }
        var options: [CFString: Any] = [:]
        if screenshotFormat != .png {
            options[kCGImageDestinationLossyCompressionQuality] = screenshotQuality
        }
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        if CGImageDestinationFinalize(dest) {
            print("Screenshot saved: \(url.path)")
        } else {
            print("Failed to save screenshot")
        }
    }

    @objc func setScreenshotFormat(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let fmt = ScreenshotFormat(rawValue: rawValue) else { return }
        screenshotFormat = fmt
        UserDefaults.standard.set(rawValue, forKey: "screenshotFormat")
    }

    @objc func setScreenshotQuality(_ sender: NSMenuItem) {
        screenshotQuality = Double(sender.tag) / 100.0
        UserDefaults.standard.set(sender.tag, forKey: "screenshotQuality")
    }

    // MARK: - Recording Actions

    @objc func toggleRecording(_ sender: Any?) {
        if isRecording { stopRecording() } else { startRecording() }
    }

    @objc func setRecordingCodec(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        recordingCodec = AVVideoCodecType(rawValue: rawValue)
        UserDefaults.standard.set(rawValue, forKey: "recordingCodec")
    }

    func startRecording() {
        guard let sess = session, !isRecording else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.movie]
        panel.nameFieldStringValue = "NanoKVM-Recording.mov"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Remove existing file if overwriting
        try? FileManager.default.removeItem(at: url)

        let output = AVCaptureMovieFileOutput()
        let codec = recordingCodec
        isRecording = true
        updateRecordToolbarIcon()

        sessionQueue.async { [weak self] in
            guard let self else { return }
            sess.beginConfiguration()
            guard sess.canAddOutput(output) else {
                sess.commitConfiguration()
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.updateRecordToolbarIcon()
                }
                print("Failed to add movie output"); return
            }
            sess.addOutput(output)
            sess.commitConfiguration()

            if let conn = output.connection(with: .video) {
                output.setOutputSettings([AVVideoCodecKey: codec], for: conn)
            }

            self.movieFileOutput = output
            output.startRecording(to: url, recordingDelegate: self)
            print("Recording started: \(url.path)")
        }
    }

    func stopRecording() {
        guard isRecording, let output = movieFileOutput else { return }
        output.stopRecording()
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        let sess = session
        sessionQueue.async {
            if let sess {
                sess.beginConfiguration()
                sess.removeOutput(output)
                sess.commitConfiguration()
            }
        }
        isRecording = false
        movieFileOutput = nil
        DispatchQueue.main.async { [weak self] in
            self?.updateRecordToolbarIcon()
        }
        if let error {
            print("Recording failed: \(error.localizedDescription)")
        } else {
            print("Recording saved: \(url.path)")
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === frameOutput {
            recordFrameMetrics(sampleBuffer)
            latestPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            // Detect actual resolution from incoming frames
            if let pb = latestPixelBuffer {
                let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
                if w != videoW || h != videoH {
                    videoW = w; videoH = h
                    DispatchQueue.main.async { [weak self] in
                        self?.window?.contentAspectRatio = NSSize(width: w, height: h)
                        self?.recalcRect()
                    }
                }
            }
            if isBackgroundRefresh {
                isBackgroundRefresh = false
                let img = cgImageFromLatestBuffer()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.lastBackgroundSnapshotAt = Date()
                    if let img {
                        self.frozenLayer?.contents = img
                    }
                    self.updateBackgroundStatusLayer()
                    guard self.usesPeriodicBackgroundRefresh(),
                          self.window?.isKeyWindow != true else { return }
                    self.sessionQueue.async { self.session?.stopRunning() }
                    self.startBackgroundRefreshTimer()
                }
            }
            if waitingForForegroundFrame {
                let img = latestPixelBuffer.flatMap { cgImage(from: $0) }
                DispatchQueue.main.async { [weak self] in
                    self?.finishForegroundResume(with: img)
                }
            }
            // Disable frame delivery in steady state — preview layer renders via GPU.
            // Keep it enabled only while Debug is open so FPS/drop estimates can update.
            if !shouldKeepFrameOutputEnabled() {
                disableFrameOutput()
            }
            // Cancel session watchdog — frame arrived, session is healthy
            DispatchQueue.main.async { [weak self] in
                self?.sessionWatchdog?.cancel()
                self?.sessionWatchdog = nil
            }
            return
        }
    }

    func updateRecordToolbarIcon() {
        guard let items = window?.toolbar?.items else { return }
        for item in items where item.itemIdentifier == .record {
            if isRecording {
                let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
                item.image = NSImage(systemSymbolName: "record.circle.fill",
                                     accessibilityDescription: "Stop Recording")?
                    .withSymbolConfiguration(config)
            } else {
                item.image = NSImage(systemSymbolName: "circle.fill",
                                     accessibilityDescription: "Record")
            }
        }
    }
}

// MARK: - Bootstrap

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Toggle Fullscreen",
    action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
appMenu.addItem(withTitle: "Quit NanoKVM",
    action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu
app.mainMenu = mainMenu
let delegate = AppDelegate()
app.delegate = delegate
app.activate(ignoringOtherApps: true)
print("NanoKVM -- Cmd+F fullscreen, Cmd+Q quit")
app.run()
