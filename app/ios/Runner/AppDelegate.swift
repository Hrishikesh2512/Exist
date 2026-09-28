import CoreBluetooth
import CoreLocation
import CryptoKit
import DeviceCheck
import Flutter
import UIKit
import UserNotifications

// All native iOS code lives in this file so it needs no Xcode project changes.
// Sections: AppDelegate · Plugin (Dart bridge) · Proto · DeviceKeys · TeacherPeripheral · StudentAgent

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // iOS relaunches the app in the background when the student walks into a class
    // (iBeacon region) — the agent must exist before the event is delivered.
    StudentAgent.shared.boot()
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let r = engineBridge.pluginRegistry.registrar(forPlugin: "ExistPlugin") {
      ExistPlugin.register(with: r)
    }
  }
}

// MARK: - Plugin (Dart bridge; method names match lib/core/native.dart)

final class ExistPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  static var sink: FlutterEventSink?
  private var teacher: TeacherPeripheral?

  static func register(with registrar: FlutterPluginRegistrar) {
    let p = ExistPlugin()
    registrar.addMethodCallDelegate(p, channel: FlutterMethodChannel(name: "exist/native", binaryMessenger: registrar.messenger()))
    FlutterEventChannel(name: "exist/native/events", binaryMessenger: registrar.messenger()).setStreamHandler(p)
    StudentAgent.shared.listener = { r in emit(["type": "studentCheckin", "result": r["sectionId"] ?? ""]) }
  }

  static func emit(_ e: [String: Any]) {
    DispatchQueue.main.async { sink?(e) }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    ExistPlugin.sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    ExistPlugin.sink = nil
    return nil
  }

  private static func targets(_ raw: Any?) -> [Target] {
    (raw as? [[String: Any]] ?? []).compactMap { t in
      guard let s0 = UUID(uuidString: t["service0"] as? String ?? ""), let s1 = UUID(uuidString: t["service1"] as? String ?? ""),
        let r0 = UUID(uuidString: t["region0"] as? String ?? ""), let r1 = UUID(uuidString: t["region1"] as? String ?? "")
      else { return nil }
      return Target(service: [s0, s1], region: [r0, r1])
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    do {
      switch call.method {
      case "keys.publicKey":
        result(try DeviceKeys.publicKeySpki().base64EncodedString())
      case "keys.sign":
        guard let data = call.arguments as? FlutterStandardTypedData else { throw ExistError("no data") }
        result(FlutterStandardTypedData(bytes: try DeviceKeys.sign(data.data)))
      case "keys.attest":
        DeviceKeys.attest(challengeB64: args["challenge"] as? String ?? "") { result($0) }
      case "keys.reset":
        DeviceKeys.reset()
        result(nil)
      case "system.state":
        result([
          "bluetooth": StudentAgent.shared.bluetoothState(),
          "canAdvertise": true,
          "backgroundOk": CLLocationManager.authorizationStatus() == .authorizedAlways,
          "sdk": 0,
          "model": DeviceKeys.modelIdentifier(),
          // Shown to admins only; resets on reinstall and is never trusted for security.
          "installId": UIDevice.current.identifierForVendor?.uuidString ?? "",
        ])
      case "system.requestBackgroundExemption":
        result(nil)
      case "system.notify":
        Reminders.now(args["title"] as? String ?? "Exist", args["body"] as? String ?? "")
        result(nil)
      case "teacher.start":
        let t = teacher ?? TeacherPeripheral()
        teacher = t
        let targets = ExistPlugin.targets(args["targets"])
        guard !targets.isEmpty, let c = args["challenge"] as? FlutterStandardTypedData else { throw ExistError("bad arguments") }
        t.start(targets: targets, toggle: args["toggle"] as? Int ?? 0, challenge: c.data)
        result(nil)
      case "teacher.update":
        guard let c = args["challenge"] as? FlutterStandardTypedData else { throw ExistError("bad arguments") }
        teacher?.update(toggle: args["toggle"] as? Int ?? 0, challenge: c.data)
        result(nil)
      case "teacher.respond":
        teacher?.respond(id: args["id"] as? Int ?? 0, code: args["code"] as? Int ?? 2)
        result(nil)
      case "teacher.stop":
        teacher?.stop()
        teacher = nil
        result(nil)
      case "teacher.scheduleAlarms":
        // iOS cannot start advertising in the background: remind the teacher to open the app.
        let items = args["items"] as? [[String: Any]] ?? []
        Reminders.schedule(prefix: "teacher-", items: items.map { ($0["at"] as? Int ?? 0, $0["title"] as? String ?? "Class starting", "Open Exist to start attendance.") })
        result(nil)
      case "student.configure":
        StudentAgent.shared.configure(
          deviceId: args["deviceId"] as? String ?? "",
          subjects: args["subjects"] as? [[String: Any]] ?? [],
          windows: args["windows"] as? [[String: Any]] ?? [])
        result(nil)
      case "student.log":
        result(StudentAgent.shared.log())
      case "student.checkNow":
        StudentAgent.shared.checkNow { result($0) }
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      result(FlutterError(code: "native", message: "\(error)", details: nil))
    }
  }
}

struct ExistError: Error, CustomStringConvertible {
  let description: String
  init(_ d: String) { description = d }
}

enum Reminders {
  static func schedule(prefix: String, items: [(Int, String, String)]) {
    let c = UNUserNotificationCenter.current()
    c.getPendingNotificationRequests { pending in
      c.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
      for (at, title, body) in items where at > Int(Date().timeIntervalSince1970 * 1000) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let date = Date(timeIntervalSince1970: Double(at) / 1000)
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        c.add(UNNotificationRequest(identifier: "\(prefix)\(at)", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
      }
    }
  }

  static func now(_ title: String, _ body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
  }
}

// MARK: - Proto (byte layouts of protocol v1, see backend/src/crypto/protocol.ts)

enum Proto {
  static let version: UInt8 = 1
  static let challengeChar = CBUUID(string: "6a1f0001-7e57-4e1a-9d2b-3c5e0b1d7a01")
  static let checkinChar = CBUUID(string: "6a1f0002-7e57-4e1a-9d2b-3c5e0b1d7a01")
  static let phaseNames: [UInt8: String] = [1: "ARRIVE", 2: "MID", 3: "END"]

  struct Challenge {
    let shortId: UInt32, slot: UInt64, token: UInt32, phase: UInt8, windowIndex: UInt8
    var phaseName: String { Proto.phaseNames[phase] ?? "ARRIVE" }
  }

  static func be<T: FixedWidthInteger>(_ d: Data, _ off: Int, _: T.Type) -> T {
    d.subdata(in: off..<(off + MemoryLayout<T>.size)).reduce(T(0)) { ($0 << 8) | T($1) }
  }

  static func bytes<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }

  static func decodeChallenge(_ raw: Data?) -> Challenge? {
    guard let d = raw.map({ Data($0) }), d.count == 19, d[0] == version else { return nil }
    return Challenge(shortId: be(d, 1, UInt32.self), slot: be(d, 5, UInt64.self), token: be(d, 13, UInt32.self), phase: d[17], windowIndex: d[18])
  }

  static func uuidData(_ u: UUID) -> Data { withUnsafeBytes(of: u.uuid) { Data($0) } }

  static func checkinBody(_ c: Challenge, deviceId: UUID, nonce: Data, clientTs: UInt64) -> Data {
    var d = Data([version])
    d += bytes(c.shortId) + bytes(c.slot) + bytes(c.token) + uuidData(deviceId) + nonce + bytes(clientTs)
    return d
  }

  static func signedMessage(_ body: Data) -> Data { Data("EXST-CHK".utf8) + body }
}

// MARK: - DeviceKeys (Secure Enclave P-256; the private key never leaves the chip)

enum DeviceKeys {
  static let tag = "edu.exist.devicekey.v1".data(using: .utf8)!
  // DER header of a P-256 SubjectPublicKeyInfo; followed by the 65-byte uncompressed point.
  static let spkiHeader = Data([0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
                                0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00])

  static func privateKey() throws -> SecKey {
    let query: [String: Any] = [
      kSecClass as String: kSecClassKey,
      kSecAttrApplicationTag as String: tag,
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecReturnRef as String: true,
    ]
    var item: CFTypeRef?
    if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let k = item {
      return k as! SecKey
    }
    var err: Unmanaged<CFError>?
    guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &err) else {
      throw err!.takeRetainedValue() as Error
    }
    var attrs: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeySizeInBits as String: 256,
      kSecPrivateKeyAttrs as String: [
        kSecAttrIsPermanent as String: true,
        kSecAttrApplicationTag as String: tag,
        kSecAttrAccessControl as String: access,
      ],
    ]
    #if !targetEnvironment(simulator)
      attrs[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
    #endif
    guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &err) else { throw err!.takeRetainedValue() as Error }
    return key
  }

  static func publicKeySpki() throws -> Data {
    var err: Unmanaged<CFError>?
    guard let pub = SecKeyCopyPublicKey(try privateKey()), let raw = SecKeyCopyExternalRepresentation(pub, &err) as Data? else {
      throw ExistError("no public key")
    }
    return spkiHeader + raw
  }

  static func sign(_ data: Data) throws -> Data {
    var err: Unmanaged<CFError>?
    guard let sig = SecKeyCreateSignature(try privateKey(), .ecdsaSignatureMessageX962SHA256, data as CFData, &err) as Data? else {
      throw err!.takeRetainedValue() as Error
    }
    return sig
  }

  /// App Attest: proves this is the genuine app on a genuine device. clientDataHash is the
  /// SHA-256 of the Secure Enclave key, which ties the two together.
  static func attest(challengeB64: String, done: @escaping (String) -> Void) {
    guard #available(iOS 14.0, *), DCAppAttestService.shared.isSupported, let challenge = Data(base64Encoded: challengeB64) else {
      return done("")
    }
    let svc = DCAppAttestService.shared
    svc.generateKey { keyId, err in
      guard let keyId = keyId, err == nil else { return DispatchQueue.main.async { done("") } }
      svc.attestKey(keyId, clientDataHash: challenge) { att, err in
        let json: [String: Any] = ["type": "app-attest", "keyId": keyId, "attestation": att?.base64EncodedString() ?? "", "error": err.map { "\($0)" } ?? ""]
        let s = (try? JSONSerialization.data(withJSONObject: json)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        DispatchQueue.main.async { done(s) }
      }
    }
  }

  /// e.g. "iPhone15,2".
  static func modelIdentifier() -> String {
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: &info.machine) { raw in
      String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
  }

  static func reset() {
    SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag] as CFDictionary)
  }
}

// MARK: - TeacherPeripheral
// iOS can advertise either an iBeacon or a service UUID, not both, so they alternate every
// ~0.7 s, rotating through the class's subject groups. Advertising only works while the app is
// on screen (Apple restriction). Check-in writes are answered after Dart verifies them.

struct Target {
  let service: [UUID]  // [toggle 0, toggle 1]
  let region: [UUID]
}

final class TeacherPeripheral: NSObject, CBPeripheralManagerDelegate {
  private var pm: CBPeripheralManager!
  private var targets: [Target] = []
  private var toggle = 0
  private var challenge = Data()
  private var timer: Timer?
  private var step = 0
  private var pendingStart = false
  private var pending: [Int: CBATTRequest] = [:]
  private var nextId = 1

  override init() {
    super.init()
    pm = CBPeripheralManager(delegate: self, queue: nil)
  }

  func start(targets t: [Target], toggle tg: Int, challenge c: Data) {
    targets = t
    toggle = tg
    challenge = c
    pendingStart = true
    if pm.state == .poweredOn { setUp() }
  }

  func update(toggle tg: Int, challenge c: Data) {
    challenge = c
    if tg != toggle {
      toggle = tg
      advertiseNext()  // show the new variant immediately
    }
  }

  /// code: 0 accepted, 1 not in this class, 2 invalid / try again.
  func respond(id: Int, code: Int) {
    guard let r = pending.removeValue(forKey: id) else { return }
    let result: CBATTError.Code = code == 0 ? .success : code == 1 ? .insufficientAuthorization : .unlikelyError
    pm.respond(to: r, withResult: result)
  }

  func stop() {
    pendingStart = false
    timer?.invalidate()
    timer = nil
    for id in Array(pending.keys) { respond(id: id, code: 2) }
    pm.stopAdvertising()
    pm.removeAllServices()
  }

  private func setUp() {
    guard pendingStart else { return }
    pendingStart = false
    pm.removeAllServices()
    for t in targets {
      for u in t.service {
        let read = CBMutableCharacteristic(type: Proto.challengeChar, properties: [.read], value: nil, permissions: [.readable])
        let write = CBMutableCharacteristic(type: Proto.checkinChar, properties: [.write], value: nil, permissions: [.writeable])
        let svc = CBMutableService(type: CBUUID(nsuuid: u), primary: true)
        svc.characteristics = [read, write]
        pm.add(svc)
      }
    }
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in self?.advertiseNext() }
    advertiseNext()
  }

  private func advertiseNext() {
    guard !targets.isEmpty else { return }
    pm.stopAdvertising()
    step += 1
    let t = targets[(step / 2) % targets.count]
    if step % 2 == 0 {
      let beacon = CLBeaconRegion(uuid: t.region[toggle], major: 0, minor: 0, identifier: "exist")
      if let data = beacon.peripheralData(withMeasuredPower: nil) as? [String: Any] { pm.startAdvertising(data) }
    } else {
      pm.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [CBUUID(nsuuid: t.service[toggle])]])
    }
  }

  func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
    if p.state == .poweredOn { setUp() } else { ExistPlugin.emit(["type": "teacherError", "message": "Bluetooth is off"]) }
  }

  func peripheralManager(_ p: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
    guard request.characteristic.uuid == Proto.challengeChar, request.offset <= challenge.count else {
      return p.respond(to: request, withResult: .invalidOffset)
    }
    request.value = challenge.subdata(in: request.offset..<challenge.count)
    p.respond(to: request, withResult: .success)
  }

  func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
    // Long (prepared) writes arrive together; stitch them by offset.
    var data = Data()
    for r in requests.sorted(by: { $0.offset < $1.offset }) where r.characteristic.uuid == Proto.checkinChar {
      if let v = r.value, r.offset == data.count { data += v }
    }
    guard let first = requests.first else { return }
    if data.isEmpty || data.count > 256 { return p.respond(to: first, withResult: .invalidAttributeValueLength) }
    let id = nextId
    nextId += 1
    pending[id] = first
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.respond(id: id, code: 2) }
    ExistPlugin.emit(["type": "checkin", "id": id, "data": FlutterStandardTypedData(bytes: data)])
  }
}

// MARK: - StudentAgent
// Registers two iBeacon regions per subject (the teacher phone flips between them whenever a
// check opens). iOS wakes this app on entering a region, even if it was closed; the agent then
// finds the teacher's phone for that subject, reads the challenge and writes a signed check-in.
// Only the student's own subjects are registered, so other classes never wake it.

final class StudentAgent: NSObject, CLLocationManagerDelegate, CBCentralManagerDelegate, CBPeripheralDelegate {
  static let shared = StudentAgent()
  var listener: (([String: Any]) -> Void)?

  private let defaults = UserDefaults.standard
  private var location: CLLocationManager!
  private var central: CBCentralManager!
  private var booted = false
  private static let forgetMs = 10 * 60_000

  struct Subject {
    let sectionId: String, title: String, service: [CBUUID], region: [UUID]
  }

  // Current attempt
  private var target: Subject?
  private var force = false
  private var connected: CBPeripheral?
  private var challenge: Proto.Challenge?
  private var completion: (([String: Any]) -> Void)?
  private var bgTask: UIBackgroundTaskIdentifier = .invalid
  private var waitTask: UIBackgroundTaskIdentifier = .invalid
  private var queue: [(Subject, Bool, Int, (([String: Any]) -> Void)?)] = []  // subject, force, toggle, completion
  private var currentToggle = -1
  private var timeout: DispatchWorkItem?
  private var retries: [String: Int] = [:]
  private var scanningAny = false

  func boot() {
    guard !booted else { return }
    booted = true
    location = CLLocationManager()
    location.delegate = self
    central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionRestoreIdentifierKey: "exist-central", CBCentralManagerOptionShowPowerAlertKey: false])
  }

  func bluetoothState() -> String {
    switch central.state {
    case .poweredOn: return "on"
    case .poweredOff: return "off"
    case .unauthorized: return "unauthorized"
    case .unsupported: return "unsupported"
    default: return "unknown"
    }
  }

  // MARK: config & state

  func configure(deviceId: String, subjects: [[String: Any]], windows: [[String: Any]]) {
    defaults.set(deviceId, forKey: "exist.deviceId")
    defaults.set(subjects, forKey: "exist.subjects")
    registerRegions()
    Reminders.schedule(prefix: "student-", items: windows.compactMap { w in
      guard let from = (w["from"] as? NSNumber)?.intValue else { return nil }
      // "from" is 15 min before class: remind 10 min before class.
      return (from + 5 * 60_000, "\(w["title"] as? String ?? "Class") soon", "Keep Bluetooth on. Attendance is automatic.")
    })
  }

  private func loadSubjects() -> [Subject] {
    (defaults.array(forKey: "exist.subjects") as? [[String: Any]] ?? []).compactMap { o in
      guard let id = o["sectionId"] as? String,
        let s0 = UUID(uuidString: o["service0"] as? String ?? ""), let s1 = UUID(uuidString: o["service1"] as? String ?? ""),
        let r0 = UUID(uuidString: o["region0"] as? String ?? ""), let r1 = UUID(uuidString: o["region1"] as? String ?? "")
      else { return nil }
      return Subject(sectionId: id, title: o["title"] as? String ?? "Class", service: [CBUUID(nsuuid: s0), CBUUID(nsuuid: s1)], region: [r0, r1])
    }
  }

  private var done: Set<String> {
    get { Set(defaults.stringArray(forKey: "exist.done") ?? []) }
    set { defaults.set(Array(newValue.suffix(300)), forKey: "exist.done") }
  }

  private func state(_ id: String) -> [String: Int] { (defaults.dictionary(forKey: "exist.state") as? [String: [String: Int]])?[id] ?? [:] }
  private func setState(_ id: String, _ v: [String: Int]) {
    var all = defaults.dictionary(forKey: "exist.state") as? [String: [String: Int]] ?? [:]
    all[id] = v
    defaults.set(all, forKey: "exist.state")
  }

  func log() -> [[String: Any]] { defaults.array(forKey: "exist.log") as? [[String: Any]] ?? [] }

  private func record(_ r: [String: Any]) {
    var l = log()
    l.append(r)
    defaults.set(Array(l.suffix(200)), forKey: "exist.log")
    listener?(r)
  }

  /// iOS monitors at most 20 regions per app: 2 per subject, so up to 10 subjects.
  private func registerRegions() {
    guard CLLocationManager.isMonitoringAvailable(for: CLBeaconRegion.self) else { return }
    for r in location.monitoredRegions { location.stopMonitoring(for: r) }
    for s in loadSubjects().prefix(10) {
      for t in 0...1 {
        let region = CLBeaconRegion(uuid: s.region[t], identifier: "\(s.sectionId)|\(t)")
        region.notifyEntryStateOnDisplay = true
        region.notifyOnEntry = true
        region.notifyOnExit = false
        location.startMonitoring(for: region)
      }
    }
  }

  // MARK: region events

  func locationManager(_ m: CLLocationManager, didEnterRegion region: CLRegion) { onRegion(region) }

  func locationManager(_ m: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
    if state == .inside { onRegion(region) }
  }

  func locationManagerDidChangeAuthorization(_ m: CLLocationManager) { registerRegions() }

  private func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

  private func onRegion(_ region: CLRegion) {
    let parts = region.identifier.split(separator: "|").map(String.init)
    guard parts.count == 2, let toggle = Int(parts[1]), let s = loadSubjects().first(where: { $0.sectionId == parts[0] }) else { return }
    var st = state(s.sectionId)
    if nowMs() - (st["lastSeen"] ?? 0) > StudentAgent.forgetMs { st["handled"] = nil }
    st["lastSeen"] = nowMs()
    setState(s.sectionId, st)
    if st["handled"] == toggle { return }
    retries[s.sectionId] = 0
    // The whole class wakes at the same moment: spread connections over a few seconds.
    holdBackgroundTime()
    DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 0...3)) { [weak self] in
      self?.enqueue(s, force: false, toggle: toggle, completion: nil)
    }
  }

  /// Keeps the app alive between a region wake-up and the (delayed / retried) check-in.
  private func holdBackgroundTime() {
    guard waitTask == .invalid else { return }
    waitTask = UIApplication.shared.beginBackgroundTask(withName: "exist-wait") { [weak self] in self?.releaseBackgroundTime() }
  }

  private func releaseBackgroundTime() {
    if waitTask != .invalid {
      UIApplication.shared.endBackgroundTask(waitTask)
      waitTask = .invalid
    }
  }

  // MARK: check-in

  /// "Check in now": look for the teacher's phone of any of my subjects.
  func checkNow(completion: @escaping ([String: Any]) -> Void) {
    let subjects = loadSubjects()
    guard !subjects.isEmpty else { return completion(["ok": false, "error": "no subjects this semester"]) }
    guard central.state == .poweredOn else { return completion(["ok": false, "error": "Bluetooth is off"]) }
    guard target == nil else { return completion(["ok": false, "error": "busy"]) }
    // Scan for all my subjects; the first one found is the class in this room.
    scanningAny = true
    completion_any = completion
    central.scanForPeripherals(withServices: subjects.flatMap { $0.service }, options: nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
      guard let self = self, self.scanningAny else { return }
      self.scanningAny = false
      self.central.stopScan()
      self.completion_any?(["ok": false, "error": "no class of yours nearby"])
      self.completion_any = nil
    }
  }

  private var completion_any: (([String: Any]) -> Void)?

  private func enqueue(_ s: Subject, force: Bool, toggle: Int, completion: (([String: Any]) -> Void)?) {
    if target?.sectionId == s.sectionId && completion == nil { return }
    queue.append((s, force, toggle, completion))
    next()
  }

  private func next() {
    guard target == nil, !queue.isEmpty else { return }
    let (s, f, t, c) = queue.removeFirst()
    target = s
    force = f
    currentToggle = t
    completion = c
    challenge = nil
    // ~30 s of background time is enough for scan → connect → read → write.
    bgTask = UIApplication.shared.beginBackgroundTask(withName: "exist-checkin") { [weak self] in self?.finish(["ok": false, "error": "background time expired"]) }
    let w = DispatchWorkItem { [weak self] in self?.finish(["ok": false, "error": "teacher's phone not found"]) }
    timeout = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: w)
    if central.state == .poweredOn { central.scanForPeripherals(withServices: s.service, options: nil) }
  }

  private func finish(_ result: [String: Any]) {
    guard let s = target else { return }
    timeout?.cancel()
    central.stopScan()
    if let p = connected { central.cancelPeripheralConnection(p) }
    connected = nil
    var r = result
    r["sectionId"] = s.sectionId
    r["title"] = s.title
    r["at"] = nowMs()
    if let c = challenge {
      r["phase"] = c.phaseName
      r["windowIndex"] = Int(c.windowIndex)
    }
    if r["skipped"] as? Bool != true { record(r) }
    let ok = r["ok"] as? Bool == true
    let settled = ok || r["skipped"] as? Bool == true || r["error"] as? String == "not in this class"
    if settled && currentToggle >= 0 {
      var st = state(s.sectionId)
      st["handled"] = currentToggle
      setState(s.sectionId, st)
    }
    if ok && UIApplication.shared.applicationState != .active {
      Reminders.now("Attendance marked", "\(s.title): \((r["phase"] as? String ?? "").lowercased())")
    }
    completion?(r)
    let automatic = completion == nil
    completion = nil
    target = nil
    if bgTask != .invalid {
      UIApplication.shared.endBackgroundTask(bgTask)
      bgTask = .invalid
    }
    // Busy teacher phone (many students at once): try again shortly, at most twice.
    if automatic && !settled && (retries[s.sectionId] ?? 0) < 2 {
      retries[s.sectionId, default: 0] += 1
      let t = currentToggle
      DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 3...8)) { [weak self] in
        self?.enqueue(s, force: false, toggle: t, completion: nil)
      }
    } else if queue.isEmpty {
      releaseBackgroundTime()
    }
    next()
  }

  func centralManagerDidUpdateState(_ c: CBCentralManager) {
    if c.state == .poweredOn, let s = target { c.scanForPeripherals(withServices: s.service, options: nil) }
    ExistPlugin.emit(["type": "bluetooth", "state": bluetoothState()])
  }

  func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {}

  func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
    guard RSSI.intValue > -95, RSSI.intValue != 127 else { return }
    if scanningAny {
      // "Check in now": which of my subjects is this?
      let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
      guard let s = loadSubjects().first(where: { sub in sub.service.contains(where: { uuids.contains($0) }) }) else { return }
      scanningAny = false
      c.stopScan()
      let cb = completion_any
      completion_any = nil
      let toggle = uuids.contains(s.service[1]) ? 1 : 0
      enqueue(s, force: true, toggle: toggle, completion: cb)
      return
    }
    guard target != nil, connected == nil else { return }
    c.stopScan()
    connected = p
    p.delegate = self
    c.connect(p, options: nil)
  }

  func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
    guard let s = target else { return }
    p.discoverServices(s.service)
  }

  func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
    finish(["ok": false, "error": "could not connect"])
  }

  func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
    if target != nil && p == connected { finish(["ok": false, "error": "disconnected"]) }
  }

  func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
    guard let s = target, let svc = p.services?.first(where: { s.service.contains($0.uuid) }) else {
      return finish(["ok": false, "error": "not this class"])
    }
    p.discoverCharacteristics([Proto.challengeChar, Proto.checkinChar], for: svc)
  }

  func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
    guard let c = svc.characteristics?.first(where: { $0.uuid == Proto.challengeChar }) else { return finish(["ok": false, "error": "not this class"]) }
    p.readValue(for: c)
  }

  func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
    guard error == nil, let c = Proto.decodeChallenge(ch.value) else { return finish(["ok": false, "error": "bad challenge"]) }
    challenge = c
    let doneKey = "\(c.shortId)|\(c.phaseName)|\(c.windowIndex)"
    let arrived = done.contains { $0.hasPrefix("\(c.shortId)|") }
    if (c.phase == 1 && arrived && !force) || done.contains(doneKey) { return finish(["ok": false, "skipped": true]) }
    guard let deviceId = UUID(uuidString: defaults.string(forKey: "exist.deviceId") ?? "") else {
      return finish(["ok": false, "error": "phone not registered"])
    }
    var nonce = Data(count: 8)
    _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }
    let body = Proto.checkinBody(c, deviceId: deviceId, nonce: nonce, clientTs: UInt64(Date().timeIntervalSince1970 * 1000))
    guard let sig = try? DeviceKeys.sign(Proto.signedMessage(body)),
      let w = ch.service?.characteristics?.first(where: { $0.uuid == Proto.checkinChar })
    else { return finish(["ok": false, "error": "signing failed"]) }
    p.writeValue(body + Data([UInt8(sig.count)]) + sig, for: w, type: .withResponse)
  }

  func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
    guard let c = challenge else { return finish(["ok": false, "error": "write failed"]) }
    if let e = error as NSError? {
      // iPhone teacher: insufficientAuthorization (8); Android teacher: application error 0x80.
      let notInClass = e.domain == CBATTErrorDomain && (e.code == CBATTError.insufficientAuthorization.rawValue || e.code == 0x80)
      return finish(["ok": false, "error": notInClass ? "not in this class" : "not accepted, retrying"])
    }
    var d = done
    d.insert("\(c.shortId)|\(c.phaseName)|\(c.windowIndex)")
    done = d
    finish(["ok": true])
  }
}
