import Foundation
import Security
import Darwin

struct TVDevice:Codable,Identifiable,Equatable,Sendable {
    enum Kind:String,Codable,CaseIterable,Sendable {case rootedLG,lg,samsung
        var title:String {switch self {case .rootedLG:"LG · Thuis";case .lg:"LG webOS";case .samsung:"Samsung Tizen"}}
    }
    var id:String=UUID().uuidString
    var name:String
    var host:String
    var mac:String=""
    var kind:Kind
    var model:String=""
    var port:Int=0
    var config:TVConfig {TVConfig(host:host,mac:mac)}
    var websocketPort:Int {port > 0 ? port : kind == .samsung ? 8002 : 3001}
    var valid:Bool {config.valid && !name.trimmingCharacters(in:.whitespaces).isEmpty && (mac.isEmpty || mac.range(of:"^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$",options:.regularExpression) != nil) && (port == 0 || (1...65535).contains(port))}
    static func initial()->TVDevice {let c=TVConfig.saved;return TVDevice(id:"default-lg",name:"LG webOS",host:c.host,mac:c.mac,kind:.lg,model:"")}
}
enum PairingVault {
    static var memoryOnly=false
    private static var memory:[String:String]=[:]
    static func get(_ id:String,interactive:Bool=false)->String? {
        if let cached=memory[id] {return cached}
        // A protected Keychain item is deliberately read only after an
        // explicit pairing action. Polling must never create password sheets.
        guard interactive else {return nil}
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"nl.dextiny.thuis.tv-pairing",kSecAttrAccount as String:id,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result:CFTypeRef?;guard SecItemCopyMatching(query as CFDictionary,&result)==errSecSuccess,let data=result as? Data,let value=String(data:data,encoding:.utf8) else {return nil}
        // Older builds could save this placeholder after a Samsung connection
        // event without a token. It cannot authenticate a later connection.
        guard value != "approved" else {SecItemDelete(query as CFDictionary);return nil}
        memory[id]=value
        return value
    }
    static func save(_ value:String,id:String)throws {
        memory[id]=value
        if memoryOnly {return}
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"nl.dextiny.thuis.tv-pairing",kSecAttrAccount as String:id]
        let update:[String:Any]=[kSecValueData as String:Data(value.utf8)]
        let status=SecItemUpdate(query as CFDictionary,update as CFDictionary)
        if status==errSecItemNotFound {var add=query;add.merge(update,uniquingKeysWith:{$1});add[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;guard SecItemAdd(add as CFDictionary,nil)==errSecSuccess else {throw ControlError.message("Koppeling kon niet in Sleutelhanger worden bewaard.")}}
        else if status != errSecSuccess {throw ControlError.message("Sleutelhanger kon de koppeling niet bewaren.")}
    }
    static func remove(_ id:String) {memory[id]=nil;SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"nl.dextiny.thuis.tv-pairing",kSecAttrAccount as String:id] as CFDictionary)}
}
// TV certificates are commonly self-signed. Trust is limited to the explicitly
// selected TV's exact IP, not redirects, web pages or arbitrary other hosts.
final class LocalTVTrust:NSObject,URLSessionDelegate,@unchecked Sendable {
    let host:String
    init(host:String){self.host=host}
    func urlSession(_ session:URLSession,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping(URLSession.AuthChallengeDisposition,URLCredential?)->Void) {
        if challenge.protectionSpace.authenticationMethod==NSURLAuthenticationMethodServerTrust,challenge.protectionSpace.host==host,let trust=challenge.protectionSpace.serverTrust {completionHandler(.useCredential,URLCredential(trust:trust))}
        else {completionHandler(.performDefaultHandling,nil)}
    }
}
@MainActor final class TVSocket {
    private let session:URLSession
    private let socket:URLSessionWebSocketTask
    private var receiver:Task<Void,Never>?
    private struct Pending {let id:String;let event:String?;let registration:Bool;let continuation:CheckedContinuation<[String:Any],Error>}
    private var pending:[String:Pending]=[:]
    private(set) var alive=true
    init(url:URL,host:String) {
        let configuration=URLSessionConfiguration.ephemeral;configuration.timeoutIntervalForRequest=8;configuration.timeoutIntervalForResource=60
        session=URLSession(configuration:configuration,delegate:LocalTVTrust(host:host),delegateQueue:nil)
        socket=session.webSocketTask(with:url);socket.maximumMessageSize=4*1024*1024;socket.resume()
        receiver=Task {[weak self] in
            guard let self else {return}
            do {while !Task.isCancelled {let response=try await socket.receive();let data:Data;switch response {case .data(let d):data=d;case .string(let text):data=Data(text.utf8);@unknown default:continue};if let json=try? JSONSerialization.jsonObject(with:data) as? [String:Any] {consume(json)}}}
            catch {failAll(ControlError.message("Verbinding met de tv verbroken. Ververs om opnieuw te verbinden."))}
        }
    }
    func close(){alive=false;receiver?.cancel();socket.cancel(with:.goingAway,reason:nil);session.invalidateAndCancel();failAll(ControlError.message("Verbinding gesloten."))}
    func send(_ body:[String:Any])async throws {try await sendText(String(decoding:try JSONSerialization.data(withJSONObject:body),as:UTF8.self))}
    func sendText(_ text:String)async throws {guard alive else {throw ControlError.message("Verbinding met de tv is gesloten.")};try await socket.send(.string(text))}
    func response(_ body:[String:Any]?,id:String=UUID().uuidString,event:String?=nil,registration:Bool=false,timeout:Double=8)async throws->[String:Any] {
        guard alive else {throw ControlError.message("Tv niet verbonden.")}
        let key=UUID().uuidString
        return try await withCheckedThrowingContinuation {continuation in
            pending[key]=Pending(id:id,event:event,registration:registration,continuation:continuation)
            Task {[weak self] in
                guard let self else {return}
                do {if let body {try await send(body)}} catch {finish(key,result:.failure(error))}
            }
            Task {[weak self] in
                try? await Task.sleep(for:.seconds(timeout))
                self?.finish(key,result:.failure(ControlError.message(registration ? "Koppelen niet bevestigd. Accepteer Thuis Control op de tv en probeer opnieuw." : "De tv antwoordde niet op deze functie.")))
            }
        }
    }
    private func finish(_ key:String,result:Result<[String:Any],Error>){pending.removeValue(forKey:key)?.continuation.resume(with:result)}
    private func failAll(_ error:Error){alive=false;let all=pending;pending.removeAll();for value in all.values {value.continuation.resume(throwing:error)}}
    private func consume(_ json:[String:Any]) {
        let type=json["type"] as? String;let event=json["event"] as? String
        if event=="ms.channel.unauthorized" || event=="ms.channel.timeOut" || (event=="ms.error" && String(describing:json["data"]).localizedCaseInsensitiveContains("authorized")) {failAll(ControlError.message("De tv weigert de koppeling. Kies opnieuw koppelen en sta de verbinding op de tv toe."));return}
        for (key,value) in pending {
            let matches=value.event != nil ? event==value.event : json["id"] as? String==value.id
            guard matches else {continue}
            if type=="error" || event=="ms.error" {finish(key,result:.failure(ControlError.message("Tv: " + (json["error"] as? String ?? "functie niet beschikbaar"))));return}
            if value.registration && value.event == nil && type != "registered" {continue}
            finish(key,result:.success(json));return
        }
    }
}
@MainActor final class StandardTV {
    let device:TVDevice
    private var socket:TVSocket?
    private var pointer:TVSocket?
    private var connecting:Task<Void,Error>?
    init(_ device:TVDevice){self.device=device}
    var paired:Bool {PairingVault.get(device.id) != nil}
    func close(){socket?.close();pointer?.close();socket=nil;pointer=nil;connecting?.cancel();connecting=nil}
    func connect(allowPairing:Bool=false)async throws {
        if let connecting {return try await connecting.value}
        if socket?.alive==true {return}
        guard allowPairing || paired else {throw ControlError.message("Koppel deze tv eerst via Televisies. Bevestig de melding op je tv.")}
        let task=Task {try await self.open(allowPairing:allowPairing)};connecting=task
        defer {connecting=nil}
        do {try await task.value} catch {socket?.close();socket=nil;throw error}
    }
    private func open(allowPairing:Bool)async throws {
        guard device.valid else {throw ControlError.message("Ongeldige tv-gegevens.")}
        let port=device.websocketPort;let scheme=[3001,8002].contains(port) ? "wss" : "ws"
        var components=URLComponents();components.scheme=scheme;components.host=device.host;components.port=port
        let key=PairingVault.get(device.id,interactive:allowPairing)
        if device.kind == .samsung {
            components.path="/api/v2/channels/samsung.remote.control"
            components.queryItems=[URLQueryItem(name:"name",value:Data("Thuis Control".utf8).base64EncodedString())]
            if let key,key != "approved" {components.queryItems?.append(URLQueryItem(name:"token",value:key))}
        }
        guard let url=components.url else {throw ControlError.message("Ongeldig tv-adres.")}
        let ws=TVSocket(url:url,host:device.host);socket=ws
        if device.kind == .lg {
            var payload:[String:Any]=["forcePairing":false,"pairingType":"PROMPT","manifest":["manifestVersion":1,"appVersion":"1.1","permissions":["CONTROL_AUDIO","CONTROL_INPUT_MEDIA_PLAYBACK","CONTROL_INPUT_TV","CONTROL_MOUSE_AND_KEYBOARD","CONTROL_POWER","LAUNCH","READ_APP_STATUS","READ_INSTALLED_APPS","READ_INPUT_DEVICE_LIST","READ_POWER_STATE","READ_RUNNING_APPS"]]]
            if let key {payload["client-key"]=key}
            let response=try await ws.response(["id":"register","type":"register","payload":payload],id:"register",registration:true,timeout:allowPairing ? 40 : 10)
            guard let value=response["payload"] as? [String:Any],let token=value["client-key"] as? String else {throw ControlError.message("LG heeft geen koppelingssleutel teruggestuurd.")}
            try PairingVault.save(token,id:device.id)
        } else {
            let response=try await ws.response(nil,event:"ms.channel.connect",registration:true,timeout:allowPairing ? 40 : 10)
            let data=response["data"] as? [String:Any] ?? [:]
            guard let token=(data["token"] as? String) ?? (data["token"] as? Int).map(String.init),!token.isEmpty else {
                throw ControlError.message("Samsung heeft geen koppelcode teruggestuurd. Kies Koppel met tv opnieuw en sta Thuis Control op de tv toe.")
            }
            try PairingVault.save(token,id:device.id)
        }
    }
    func request(_ path:String,_ payload:[String:Any]=[:])async throws->[String:Any] {
        try await connect();guard let socket else {throw ControlError.message("Geen tv-verbinding.")}
        let id=UUID().uuidString
        let response=try await socket.response(["id":id,"type":"request","uri":"ssap://"+path,"payload":payload],id:id)
        let value=response["payload"] as? [String:Any] ?? [:]
        if value["returnValue"] as? Bool==false {throw ControlError.message(value["errorText"] as? String ?? "Deze tv ondersteunt deze functie niet.")}
        return value
    }
    func samsungKey(_ key:String)async throws {
        try await connect();try await socket?.send(["method":"ms.remote.control","params":["Cmd":"Click","DataOfCmd":key,"Option":"false","TypeOfRemote":"SendRemoteKey"]])
    }
    func key(_ code:Int)async throws {
        if device.kind == .samsung {
            let keys=[103:"KEY_UP",108:"KEY_DOWN",105:"KEY_LEFT",106:"KEY_RIGHT",28:"KEY_ENTER",412:"KEY_RETURN",773:"KEY_HOME",164:"KEY_PLAYPAUSE",207:"KEY_PLAY",119:"KEY_PAUSE",128:"KEY_STOP",115:"KEY_VOLUP",114:"KEY_VOLDOWN"]
            guard let name=keys[code] else {throw ControlError.message("Deze toets wordt niet ondersteund.")};try await samsungKey(name);return
        }
        let names=[103:"UP",108:"DOWN",105:"LEFT",106:"RIGHT",28:"ENTER",412:"BACK",773:"HOME",164:"PLAYPAUSE",207:"PLAY",119:"PAUSE",128:"STOP"]
        guard let name=names[code] else {throw ControlError.message("Deze toets wordt niet ondersteund.")}
        if pointer?.alive != true {
            let response=try await request("com.webos.service.networkinput/getPointerInputSocket")
            guard let path=response["socketPath"] as? String,let url=URL(string:path),url.host==device.host,["ws","wss"].contains(url.scheme ?? "") else {throw ControlError.message("LG gaf geen geldige afstandsbedieningsverbinding.")}
            pointer=TVSocket(url:url,host:device.host)
        }
        try await pointer?.sendText("type:button\nname:\(name)\n\n")
    }
    func appList()async throws->[TVApp] {
        if device.kind == .lg {
            let data=try await request("com.webos.applicationManager/listLaunchPoints")
            return (data["launchPoints"] as? [[String:Any]] ?? []).compactMap {row in guard let id=row["id"] as? String,let title=row["title"] as? String else {return nil};return TVApp(id:id,title:title,icon:row["icon"] as? String)}
        }
        try await connect()
        guard let socket else {return []}
        let data=try await socket.response(["method":"ms.channel.emit","params":["event":"ed.installedApp.get","to":"host"]],event:"ed.installedApp.get",timeout:5)
        var content=data["data"]
        if let text=content as? String,let bytes=text.data(using:.utf8) {content=try? JSONSerialization.jsonObject(with:bytes)}
        let rows=(content as? [String:Any])?["data"] as? [[String:Any]] ?? content as? [[String:Any]] ?? []
        return rows.compactMap {row in guard let id=row["appId"] as? String ?? row["id"] as? String,let title=row["name"] as? String else {return nil};return TVApp(id:id,title:title,icon:row["icon"] as? String,launchType:(row["app_type"] as? Int).map {$0 == 2 ? "DEEP_LINK" : "NATIVE_LAUNCH"})}
    }
    func launch(_ id:String,launchType:String="DEEP_LINK")async throws {
        if device.kind == .lg {_ = try await request("system.launcher/launch",["id":id])}
        else {
            try await connect()
            try await socket?.send(["method":"ms.channel.emit","params":["event":"ed.apps.launch","to":"host","data":["action_type":launchType,"appId":id,"metaTag":""]]])
        }
    }
    func powerOff()async throws {if device.kind == .lg {_ = try await request("system/turnOff")} else {try await samsungKey("KEY_POWER")}}
}

final class DeviceDescription:NSObject,XMLParserDelegate {
    private var element="";private var text="";var values:[String:String]=[:]
    func parser(_ parser:XMLParser,didStartElement elementName:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]=[:]) {element=elementName;text=""}
    func parser(_ parser:XMLParser,foundCharacters string:String){text+=string}
    func parser(_ parser:XMLParser,didEndElement elementName:String,namespaceURI:String?,qualifiedName:String?) {if ["manufacturer","friendlyName","modelName","modelNumber"].contains(elementName),values[elementName]==nil {values[elementName]=text.trimmingCharacters(in:.whitespacesAndNewlines)};text=""}
    static func parse(_ data:Data)->[String:String] {let delegate=DeviceDescription();let parser=XMLParser(data:data);parser.shouldResolveExternalEntities=false;parser.delegate=delegate;_ = parser.parse();return delegate.values}
}
enum TVDiscovery {
    static func locations(in message:String)->URL? {
        let lines=message.components(separatedBy:.newlines)
        guard let line=lines.first(where:{$0.lowercased().hasPrefix("location:")}),let url=URL(string:String(line.dropFirst(9)).trimmingCharacters(in:.whitespacesAndNewlines)),url.scheme=="http",let host=url.host,TVConfig(host:host,mac:"").valid else {return nil}
        // Discovery is only for devices on the local network.
        let p=host.split(separator:".").compactMap {Int($0)}
        guard p[0]==10 || (p[0]==192 && p[1]==168) || (p[0]==172 && (16...31).contains(p[1])) || p[0]==127 || (p[0]==169 && p[1]==254) else {return nil}
        return url
    }
    static func scan()async throws->[TVDevice] {
        let locations:[URL]=try await withCheckedThrowingContinuation {continuation in
            DispatchQueue.global(qos:.utility).async {
                let fd=socket(AF_INET,SOCK_DGRAM,IPPROTO_UDP)
                guard fd>=0 else {continuation.resume(throwing:ControlError.message("Netwerkdetectie kon niet starten."));return}
                defer {Darwin.close(fd)}
                var timeout=timeval(tv_sec:0,tv_usec:250000);setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
                var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_port=UInt16(1900).bigEndian;inet_pton(AF_INET,"239.255.255.250",&address.sin_addr)
                for st in ["urn:lge-com:service:webos-second-screen:1","urn:samsung.com:device:RemoteControlReceiver:1","urn:samsung.com:service:MainTVAgent2:1","ssdp:all"] {
                    let bytes=Data("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: \(st)\r\n\r\n".utf8)
                    _ = bytes.withUnsafeBytes {buf in withUnsafePointer(to:&address) {$0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.sendto(fd,buf.baseAddress,buf.count,0,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}}
                }
                let end=Date().addingTimeInterval(3.5);var found=Set<URL>();var buffer=[UInt8](repeating:0,count:16384)
                while Date()<end {let count=recv(fd,&buffer,buffer.count,0);if count>0,let url=Self.locations(in:String(decoding:buffer.prefix(count),as:UTF8.self)) {found.insert(url)}}
                continuation.resume(returning:Array(found.prefix(60)))
            }
        }
        return await withTaskGroup(of:TVDevice?.self) {group in
            for url in locations {group.addTask {
                do {var req=URLRequest(url:url);req.timeoutInterval=3;let (data,_)=try await URLSession.shared.data(for:req);guard data.count<512*1024 else {return nil};let values=DeviceDescription.parse(data);let maker=(values["manufacturer"] ?? "").lowercased();let kind:TVDevice.Kind
                    if maker.contains("samsung") {kind = .samsung} else if maker.contains("lg") || maker.contains("lge") {kind = .lg} else {return nil}
                    var device=TVDevice(name:values["friendlyName"] ?? kind.title,host:url.host!,kind:kind,model:values["modelName"] ?? "")
                    if kind == .samsung,let info=await SamsungInfo.fetch(device) {device.mac=info["wifiMac"] as? String ?? "";device.model=info["modelName"] as? String ?? device.model}
                    return device
                } catch {return nil}
            }}
            var found:[String:TVDevice]=[:];for await item in group {if let item {found[item.host]=item}}
            return found.values.sorted {$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending}
        }
    }
}

enum SamsungInfo {
    static func fetch(_ device:TVDevice)async->[String:Any]? {
        guard device.kind == .samsung,[8001,8002].contains(device.websocketPort),let url=URL(string:"http://\(device.host):8001/api/v2/") else {return nil}
        do {var request=URLRequest(url:url);request.timeoutInterval=2;let (data,_)=try await URLSession.shared.data(for:request);guard data.count<512*1024,let root=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {return nil};return root["device"] as? [String:Any]} catch {return nil}
    }
}
