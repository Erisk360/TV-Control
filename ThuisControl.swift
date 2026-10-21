import SwiftUI
import AppKit
import Combine
import Darwin

// Explicit wrapper alias avoids the SDK 27 macro spelling when building with Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>

struct TVApp: Identifiable, Codable, Hashable, Sendable { let id: String; let title: String; let icon: String?; var launchType:String? = nil }
struct TVConfig: Sendable {
    var host: String; var mac: String
    // Devices are deliberately not bundled: every installation starts empty
    // and the user adds its own host and optional Wake-on-LAN MAC address.
    static var saved: TVConfig { TVConfig(host: UserDefaults.standard.string(forKey: "tvHost") ?? "", mac: UserDefaults.standard.string(forKey: "tvMAC") ?? "") }
    var key: String { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/lg-tv/root-key").path }
    var knownHosts: String { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/lg-tv/known_hosts").path }
    var valid: Bool { let parts = host.split(separator: ".", omittingEmptySubsequences: false); return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false } }
}
enum ControlError: LocalizedError { case message(String); var errorDescription: String? { switch self {case .message(let value): return value} } }
enum TVTransport {
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func run(_ command: String, config: TVConfig, tty: Bool = true) async throws -> Data {
        guard config.valid else { throw ControlError.message("Vul een geldig IPv4-adres in bij Verbinding.") }
        guard FileManager.default.fileExists(atPath: config.key) else { throw ControlError.message("De verbindingssleutel ontbreekt. Bekijk de installatie-instructies bij Verbinding.") }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process(); let output = Pipe(); let errors = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = (tty ? ["-tt"] : []) + ["-i", config.key, "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\(config.knownHosts)", "-o", "ConnectTimeout=3", "-o", "ServerAliveInterval=2", "-o", "ServerAliveCountMax=2", "root@\(config.host)", command]
                process.standardOutput = output; process.standardError = errors; process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 12, execute: watchdog)
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit(); watchdog.cancel()
                    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                    guard process.terminationStatus == 0 else {
                        let detail = String(data: errorData, encoding: .utf8) ?? ""
                        if detail.contains("Permission denied") { throw ControlError.message("De tv weigert de verbindingssleutel. Controleer de SSH-verbinding.") }
                        throw ControlError.message("De tv is niet bereikbaar. Controleer of hij aan staat en op hetzelfde netwerk zit.")
                    }
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    static func luna(_ uri: String, payload: [String: Any] = [:], config: TVConfig) async throws -> [String: Any] {
        let json = String(data: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), encoding: .utf8)!
        let data = try await run("/usr/bin/luna-send -n 1 -w 4000 \(quote(uri)) \(quote(json))", config: config)
        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.components(separatedBy: .newlines) {
            if let encoded = line.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] {
                if value["returnValue"] as? Bool == false { throw ControlError.message("De tv weigerde de opdracht: \(value["errorText"] as? String ?? uri)") }
                return value
            }
        }
        throw ControlError.message("De tv gaf geen bruikbaar antwoord. Probeer opnieuw.")
    }
    static func apps(config: TVConfig) async throws -> [TVApp] {
        let data = try await run("curl -fsS --max-time 5 http://127.0.0.1:17389/catalog?refresh=1", config: config, tty: false)
        struct Catalog: Decodable { let apps: [TVApp] }
        return try JSONDecoder().decode(Catalog.self, from: data).apps.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
    static func wake(config: TVConfig) throws {
        let bytes = config.mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard config.mac.range(of: "^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$", options: .regularExpression) != nil, bytes.count == 6 else { throw ControlError.message("Vul een geldig MAC-adres in bij Verbinding.") }
        var packet = [UInt8](repeating: 255, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw ControlError.message("Kan geen wekbericht versturen.") }
        defer { Darwin.close(descriptor) }
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw ControlError.message("Broadcast is niet beschikbaar op dit netwerk.") }
        let parts = config.host.split(separator: ".").dropLast().joined(separator: ".")
        var sent = false
        for target in [parts + ".255", "255.255.255.255", config.host] {
            var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(9).bigEndian
            inet_pton(AF_INET, target, &address.sin_addr)
            let result = packet.withUnsafeBytes { buffer in withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.sendto(descriptor, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
            if result == packet.count { sent = true }
        }
        if !sent { throw ControlError.message("Het wekbericht kon niet worden verstuurd. Controleer netwerktoegang.") }
    }
}

struct TVInput: Decodable, Identifiable { let id: String; let label: String; let appId: String; let connected: Bool }

@MainActor final class TVModel:ObservableObject {
    @Published var devices:[TVDevice]
    @Published var selectedID:String
    @Published var config:TVConfig
    @Published var discovered:[TVDevice]=[]
    @Published var showDevices=false
    @Published var scanning=false
    @Published var pairing=false
    @Published var apps:[TVApp]=[]
    @Published var inputs:[TVInput]=[]
    @Published var images:[String:NSImage]=[:]
    @Published var connected=false
    @Published var power="Onbekend"
    @Published var foreground=""
    @Published var volume=0.0
    @Published var muted=false
    @Published var error:String?
    @Published var notice:String?
    @Published var message="Verbinding maken…"
    @Published var refreshing=false
    @Published var waking=false
    @Published var switchingOff=false
    @Published var pendingApp:String?
    @Published var commandCount=0
    @Published var favorites:[String]=[]
    var adjustingVolume=false
    private var backend:TVBackend
    private var generation=UUID()
    private var fetchingIcons=Set<String>()
    private var commandTask:Task<Void,Never>?
    private var volumeTask:Task<Void,Never>?
    private var followup:Task<Void,Never>?
    private var powerTask:Task<Void,Never>?
    private var expectedStandby=false
    var selected:TVDevice {devices.first(where:{$0.id==selectedID}) ?? devices[0]}
    var rooted:Bool {selected.kind == .rootedLG}
    var isSamsung:Bool {selected.kind == .samsung}
    var paired:Bool {backend.paired}
    var supportsVolumeLevel:Bool {!isSamsung}
    var active:Bool {connected && Self.isAwake(power) && !changingPower}
    var changingPower:Bool {waking || switchingOff}
    var busy:Bool {commandCount>0 || changingPower || pairing}
    nonisolated static func isAwake(_ state:String)->Bool {["Active","Screen Saver"].contains(state)}
    var homeApp:TVApp {TVApp(id:rooted ? "nl.dextiny.thuis" : "__home",title:rooted ? "Thuis" : isSamsung ? "Smart Hub" : "LG Home",icon:nil)}
    var library:[TVApp] {[homeApp]+apps.filter {$0.id != homeApp.id}}
    var currentApp:TVApp {apps.first(where:{$0.id==foreground}) ?? TVApp(id:foreground.isEmpty ? homeApp.id : foreground,title:foreground.isEmpty || foreground == homeApp.id ? homeApp.title : foreground.contains("hdmi") ? "HDMI "+String(foreground.suffix(1)) : selected.name,icon:nil)}
    var appTitle:String {currentApp.title}
    var pinnedApps:[TVApp] {favorites.compactMap {id in library.first(where:{$0.id==id})}}
    var onlineLabel:String {pairing ? "Bevestig op je tv…" : waking ? "Wordt aangezet…" : switchingOff ? "Naar stand-by…" : active ? "Verbonden" : !paired ? "Nog niet gekoppeld" : expectedStandby || connected ? "Stand-by" : "Niet bereikbaar"}
    private func key(_ suffix:String)->String {"tv.\(selectedID).\(suffix)"}
    init() {
        let initial=TVDevice.initial()
        let saved=UserDefaults.standard.data(forKey:"tvDevices").flatMap {try? JSONDecoder().decode([TVDevice].self,from:$0)}
        let all=(saved?.isEmpty==false ? saved! : [initial]).filter {$0.valid}
        let available=all.isEmpty ? [initial] : all;devices=available
        let id=UserDefaults.standard.string(forKey:"selectedTV") ?? initial.id
        let chosen=available.first(where:{$0.id==id}) ?? available[0]
        selectedID=chosen.id;config=chosen.config;backend=TVBackend(chosen)
        loadLocal();persist()
    }
    private func loadLocal() {
        favorites=UserDefaults.standard.stringArray(forKey:key("favorites")) ?? (rooted ? UserDefaults.standard.stringArray(forKey:"favorites") : nil) ?? (isSamsung ? [] : ["netflix","com.apple.appletv","youtube.leanback.v4"])
        if let data=UserDefaults.standard.data(forKey:key("apps")),let cached=try? JSONDecoder().decode([TVApp].self,from:data) {apps=cached}
        else if rooted,let data=UserDefaults.standard.data(forKey:"cachedApps"),let cached=try? JSONDecoder().decode([TVApp].self,from:data) {apps=cached}
        expectedStandby=UserDefaults.standard.bool(forKey:key("standby"))
    }
    private func persist() {UserDefaults.standard.set(try? JSONEncoder().encode(devices),forKey:"tvDevices");UserDefaults.standard.set(selectedID,forKey:"selectedTV")}
    func select(_ id:String) {
        guard !busy,id != selectedID,let device=devices.first(where:{$0.id==id}) else {return}
        generation=UUID();backend.close();followup?.cancel();volumeTask?.cancel();volumeTask=nil
        selectedID=id;config=device.config;backend=TVBackend(device);apps=[];inputs=[];images=[:];fetchingIcons=[];connected=false;foreground="";power="Onbekend";volume=0;muted=false;notice=nil;error=nil;refreshing=false;message="Verbinding maken…";loadLocal();persist()
        Task {await refresh(includeApps:true)}
    }
    func add(_ device:TVDevice) {
        guard device.valid else {error="Vul een naam, geldig IPv4-adres en eventueel geldig MAC-adres in.";return}
        if let existing=devices.first(where:{$0.host==device.host}) {select(existing.id);message="Deze tv is al toegevoegd.";return}
        devices.append(device);persist();select(device.id)
    }
    func update(_ device:TVDevice) {
        guard !busy,device.valid,let i=devices.firstIndex(where:{$0.id==device.id}),!devices.contains(where:{$0.id != device.id && $0.host==device.host}) else {error="Controleer de tv-gegevens. Dit adres kan al toegevoegd zijn.";return}
        devices[i]=device;persist()
        if device.id==selectedID {generation=UUID();backend.close();config=device.config;backend=TVBackend(device);refreshing=false;connected=false;error=nil;Task {await refresh(includeApps:true)}}
    }
    func remove(_ id:String) {
        guard !busy,devices.count>1 else {return}
        if id==selectedID,let other=devices.first(where:{$0.id != id}) {select(other.id)}
        devices.removeAll {$0.id==id};PairingVault.remove(id);persist()
    }
    func discover() {
        guard !scanning else {return};scanning=true;error=nil
        Task {defer {scanning=false};do {discovered=try await TVDiscovery.scan();message=discovered.isEmpty ? "Geen tv gevonden. Je kunt er handmatig één toevoegen." : "\(discovered.count) tv’s gevonden"} catch {self.error=error.localizedDescription}}
    }
    func pair(replace:Bool=false) {
        guard !busy,!rooted else {return};pairing=true;error=nil;message="Sta Thuis Control toe op je tv."
        let client=backend;let token=generation
        if replace {PairingVault.remove(selectedID);client.close()}
        Task {defer {pairing=false};do {try await client.pair();guard generation==token else {return};message="Tv gekoppeld";pairing=false;await refresh(includeApps:true)} catch {self.error=error.localizedDescription}}
    }
    func refresh(includeApps:Bool=false,quiet:Bool=false)async {
        guard !refreshing,!pairing else {return}
        if !backend.paired {
            let token=generation;let current=backend;let enriched=await current.enrich()
            guard generation==token else {return}
            if let enriched,let i=devices.firstIndex(where:{$0.id==selectedID}) {devices[i]=enriched;config=enriched.config;persist()}
            connected=false;message="Koppel deze tv bij Televisies.";return
        }

        // A deliberate power-off is not followed by repeated reconnects that
        // might themselves wake a TV. Explicit refresh can check a physical wake.
        if quiet && expectedStandby && !waking && !rooted {return}
        refreshing=true;let token=generation;let client=backend
        defer {if generation==token {refreshing=false}}
        if !quiet {error=nil}
        do {
            let status=try await client.status(includeApps:includeApps || apps.isEmpty)
            guard generation==token else {return}
            connected=true;power=status.power
            if Self.isAwake(power) {expectedStandby=false;UserDefaults.standard.set(false,forKey:key("standby"))}
            if !adjustingVolume,volumeTask==nil,let value=status.volume {volume=value}
            if let value=status.muted {muted=value};if let value=status.foreground {foreground=value}
            if let value=status.apps {let manual=UserDefaults.standard.data(forKey:key("manualApps")).flatMap {try? JSONDecoder().decode([TVApp].self,from:$0)} ?? [];apps=(value+manual.filter {app in !value.contains(where:{$0.id==app.id})}).sorted {$0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending};UserDefaults.standard.set(try? JSONEncoder().encode(apps),forKey:key("apps"))}
            if let value=status.inputs {inputs=value};notice=status.notice
            if !quiet || message=="Verbinding maken…" {message=Self.isAwake(power) ? "Tv verbonden" : "Tv in stand-by"}
        } catch {
            guard generation==token else {return};connected=false
            if expectedStandby && !waking {power="Standby";message="Tv in stand-by"}
            else if !quiet && !waking {self.error=error.localizedDescription}
            if !client.paired {message="Koppel deze tv bij Televisies."}
        }
    }
    private func enqueue(label:String,refresh:Bool=false,isLaunch:Bool=false,launchID:String?=nil,operation:@escaping(TVBackend)async throws->Void,completion:(()->Void)?=nil) {
        guard commandCount<20 else {return}
        let previous=commandTask;let client=backend;let token=generation;commandCount+=1
        commandTask=Task {
            await previous?.value;defer {commandCount-=1}
            guard generation==token else {return}
            do {try await operation(client);guard generation==token else {return};error=nil;message=label;completion?()
                if refresh {followup?.cancel();followup=Task {try? await Task.sleep(for:.milliseconds(650));if !Task.isCancelled {await self.refresh(quiet:true)}}}
            } catch {if generation==token {self.error=error.localizedDescription}}
            if generation==token && isLaunch && pendingApp==launchID {pendingApp=nil}
        }
    }
    func open(_ id:String,title:String) {
        if id==homeApp.id {home();return}
        guard active,pendingApp != id else {return};pendingApp=id;let ports=inputs;let launchType=apps.first(where:{$0.id==id})?.launchType
        enqueue(label:isSamsung ? "Openopdracht verstuurd: \(title)" : "\(title) geopend",refresh:true,isLaunch:true,launchID:id,operation:{try await $0.open(id,inputs:ports,launchType:launchType)}) {self.foreground=id}
    }
    func home(){guard active else {return};enqueue(label:"Beginscherm geopend",refresh:true,operation:{try await $0.home()}) {self.foreground=self.homeApp.id}}
    func openSettings(){guard active else {return};enqueue(label:"Instellingen geopend",operation:{try await $0.settings()})}
    func openStore(){guard active else {return};enqueue(label:isSamsung ? "Smart Hub geopend" : "Appwinkel geopend",operation:{try await $0.store()})}
    func openSources(){guard active else {return};enqueue(label:"Bronnen geopend",operation:{try await $0.sources()})}
    func key(_ value:Int){guard active else {return};enqueue(label:"Afstandsbediening",operation:{try await $0.key(value)})}
    func setVolume(_ value:Double) {
        guard active,supportsVolumeLevel else {return};volume=min(100,max(0,value));volumeTask?.cancel()
        volumeTask=Task {do {try await Task.sleep(for:.milliseconds(100))} catch {return};let target=Int(volume);enqueue(label:"Volume \(target)",operation:{try await $0.setVolume(target)});volumeTask=nil}
    }
    func toggleMute(){guard active else {return};let next = !muted;enqueue(label:isSamsung ? "Dempknop verstuurd" : next ? "Geluid gedempt" : "Geluid aan",operation:{try await $0.mute(next)}) {if !self.isSamsung {self.muted=next}}}
    func turnOff() {
        guard active else {return};switchingOff=true;followup?.cancel();volumeTask?.cancel();volumeTask=nil
        let previous=commandTask;let client=backend;let token=generation
        powerTask=Task {
            defer {switchingOff=false};await previous?.value
            do {try await client.off();guard generation==token else {return};expectedStandby=true;UserDefaults.standard.set(true,forKey:key("standby"));error=nil
                if rooted {for _ in 0..<16 {try await Task.sleep(for:.milliseconds(500));if let status=try? await client.status(includeApps:false) {power=status.power;if !Self.isAwake(power) {message="Tv in stand-by";return}} else {break}}}
                power="Standby";connected=false;message="Tv in stand-by"
            } catch {self.error=error.localizedDescription}
        }
    }
    func turnOn() {
        guard !changingPower,!active else {return}
        if !paired {do {try TVTransport.wake(config:config);error=nil;message="Wekbericht verstuurd. Koppel de tv zodra hij aanstaat."} catch {self.error=error.localizedDescription};return}
        waking=true;error=nil;let client=backend;let token=generation
        powerTask=Task {
            defer {waking=false}
            do {for _ in 0..<16 {try await client.wake();try await Task.sleep(for:.seconds(2));await refresh(includeApps:apps.isEmpty,quiet:true);guard token==generation else {return};if connected && Self.isAwake(power) {expectedStandby=false;error=nil;message="Tv staat aan";return}};error="De tv reageert nog niet. Controleer netstroom, MAC-adres en wekken via het netwerk."} catch {self.error=error.localizedDescription}
        }
    }
    func toggleFavorite(_ id:String){if favorites.contains(id) {favorites.removeAll {$0==id}} else {favorites.append(id)};UserDefaults.standard.set(favorites,forKey:key("favorites"))}
    func addApp(id:String,title:String) {
        let id=id.trimmingCharacters(in:.whitespacesAndNewlines);let title=title.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !id.isEmpty,!title.isEmpty,id.count<200,title.count<100 else {error="Vul een geldige app-naam en app-ID in.";return}
        if !apps.contains(where:{$0.id==id}) {let app=TVApp(id:id,title:title,icon:nil);apps.append(app);var manual=UserDefaults.standard.data(forKey:key("manualApps")).flatMap {try? JSONDecoder().decode([TVApp].self,from:$0)} ?? [];manual.append(app);UserDefaults.standard.set(try? JSONEncoder().encode(manual),forKey:key("manualApps"));UserDefaults.standard.set(try? JSONEncoder().encode(apps),forKey:key("apps"))}
    }
    func loadIcon(_ app:TVApp)async {
        guard images[app.id]==nil,!fetchingIcons.contains(app.id),Bundle.main.url(forResource:app.id,withExtension:"png",subdirectory:"icons")==nil,let source=app.icon else {return}
        let token=generation;let device=selected;fetchingIcons.insert(app.id);defer {fetchingIcons.remove(app.id)}
        do {
            let data:Data
            if rooted {guard app.id.range(of:"^[a-zA-Z0-9._-]{1,200}$",options:.regularExpression) != nil else {return};data=try await TVTransport.run("curl -fsS --max-time 4 "+TVTransport.quote("http://127.0.0.1:17389/icon?id="+app.id),config:device.config,tty:false)}
            else {guard let url=URL(string:source),url.host==device.host,["http","https"].contains(url.scheme ?? "") else {return};var request=URLRequest(url:url);request.timeoutInterval=4;let session=URLSession(configuration:.ephemeral,delegate:LocalTVTrust(host:device.host),delegateQueue:nil);defer {session.invalidateAndCancel()};data=try await session.data(for:request).0}
            if token==generation,data.count<=4*1024*1024,let image=NSImage(data:data) {images[app.id]=image}
        } catch {}
    }
    func saveConnection(host:String,mac:String){var device=selected;device.host=host.trimmingCharacters(in:.whitespacesAndNewlines);device.mac=mac.trimmingCharacters(in:.whitespacesAndNewlines);update(device)}
}
