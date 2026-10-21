import Foundation
struct TVSnapshot {
    var power="Active"
    var volume:Double?
    var muted:Bool?
    var foreground:String?
    var apps:[TVApp]?
    var inputs:[TVInput]?
    var notice:String?
}
@MainActor final class TVBackend {
    var device:TVDevice
    private let standard:StandardTV?
    init(_ device:TVDevice){self.device=device;standard=device.kind == .rootedLG ? nil : StandardTV(device)}
    var paired:Bool {device.kind == .rootedLG || standard?.paired == true}
    // Several Samsung Tizen generations accept remote commands but do not
    // answer the private installed-app inventory event. These are launch
    // shortcuts, not a claim that every item is installed on this TV.
    private static let samsungQuickApps=[
        TVApp(id:"3201907018807",title:"Netflix",icon:nil,launchType:"NATIVE_LAUNCH"),
        TVApp(id:"111299001912",title:"YouTube",icon:nil,launchType:"NATIVE_LAUNCH"),
        TVApp(id:"3201807016597",title:"Apple TV",icon:nil,launchType:"NATIVE_LAUNCH"),
        TVApp(id:"3201910019365",title:"Prime Video",icon:nil,launchType:"NATIVE_LAUNCH"),
        TVApp(id:"3201901017640",title:"Disney+",icon:nil,launchType:"NATIVE_LAUNCH"),
        TVApp(id:"3201606009684",title:"Spotify",icon:nil,launchType:"NATIVE_LAUNCH")
    ]
    func close(){standard?.close()}
    func pair()async throws {
        if let info=await SamsungInfo.fetch(device),(info["PowerState"] as? String)?.lowercased()=="standby" {throw ControlError.message("Zet de Samsung eerst aan. Kies daarna Koppel met tv en accepteer Thuis Control op het tv-scherm.")}
        try await standard?.connect(allowPairing:true)
    }
    func enrich()async->TVDevice? {
        guard let info=await SamsungInfo.fetch(device) else {return nil}
        if device.mac.isEmpty {device.mac=info["wifiMac"] as? String ?? ""}
        if device.model.isEmpty {device.model=info["modelName"] as? String ?? ""}
        return device
    }
    private func luna(_ path:String,_ payload:[String:Any]=[:])async throws->[String:Any] {try await TVTransport.luna("luna://"+path,payload:payload,config:device.config)}
    func status(includeApps:Bool)async throws->TVSnapshot {
        var snapshot=TVSnapshot()
        if device.kind == .rootedLG {
            snapshot.power=try await luna("com.webos.service.tvpower/power/getPowerState")["state"] as? String ?? "Unknown"
            if !TVModel.isAwake(snapshot.power) {return snapshot}
            if let audio=try? await luna("com.webos.audio/getVolume") {snapshot.volume=(audio["volume"] as? Int).map(Double.init);snapshot.muted=audio["muteStatus"] as? Bool}
            snapshot.foreground=try? await luna("com.webos.applicationManager/getForegroundAppInfo")["appId"] as? String
            if includeApps {
                snapshot.apps=try await TVTransport.apps(config:device.config)
                if let raw=try? await luna("com.webos.service.apiadapter/tv/getExternalInputList"),let values=raw["devices"],let data=try? JSONSerialization.data(withJSONObject:values) {snapshot.inputs=try? JSONDecoder().decode([TVInput].self,from:data)}
            }
        } else if let standard {
            if device.kind == .samsung,let info=await SamsungInfo.fetch(device),(info["PowerState"] as? String)?.lowercased()=="standby" {snapshot.power="Standby";return snapshot}
            try await standard.connect()
            if device.kind == .lg {
                if let power=try? await standard.request("com.webos.service.tvpower/power/getPowerState") {snapshot.power=power["state"] as? String ?? "Active"}
                if !TVModel.isAwake(snapshot.power) {return snapshot}
                if let audio=try? await standard.request("audio/getVolume") {
                    let value=audio["volumeStatus"] as? [String:Any] ?? audio
                    snapshot.volume=(value["volume"] as? Int).map(Double.init);snapshot.muted=value["muted"] as? Bool ?? value["muteStatus"] as? Bool
                }
                snapshot.foreground=try? await standard.request("com.webos.applicationManager/getForegroundAppInfo")["appId"] as? String
                if includeApps {
                    snapshot.apps=try await standard.appList()
                    if let raw=try? await standard.request("tv/getExternalInputList"),let values=raw["devices"] as? [[String:Any]] {snapshot.inputs=values.compactMap {row in guard let id=row["id"] as? String else {return nil};return TVInput(id:id,label:row["label"] as? String ?? id,appId:row["appId"] as? String ?? id,connected:row["connected"] as? Bool ?? false)}}
                }
            } else if includeApps {
                do {
                    let apps=try await standard.appList()
                    if apps.isEmpty {
                        snapshot.apps=Self.samsungQuickApps
                        snapshot.notice="Samsung deelt geen geïnstalleerde applijst. Dit zijn snelkoppelingen; voeg andere apps toe met de plusknop."
                    } else {snapshot.apps=apps}
                } catch {
                    snapshot.apps=Self.samsungQuickApps
                    snapshot.notice="Samsung deelt geen geïnstalleerde applijst. Dit zijn snelkoppelingen; voeg andere apps toe met de plusknop."
                }
            }
        }
        return snapshot
    }
    func open(_ id:String,inputs:[TVInput],launchType:String?=nil)async throws {
        if device.kind == .rootedLG {_ = try await luna("com.webos.applicationManager/launch",["id":id])}
        else if device.kind == .lg,let input=inputs.first(where:{$0.appId==id}) {_ = try await standard?.request("tv/switchInput",["inputId":input.id])}
        else {try await standard?.launch(id,launchType:launchType ?? "DEEP_LINK")}
    }
    func key(_ code:Int)async throws {if device.kind == .rootedLG {_ = try await luna("com.webos.service.networkinput/test/sendKeyCode",["keyCode":code])} else {try await standard?.key(code)}}
    func home()async throws {if device.kind == .rootedLG {try await open("nl.dextiny.thuis",inputs:[])} else {try await key(773)}}
    func settings()async throws {if device.kind == .samsung {try await standard?.samsungKey("KEY_MENU")} else {try await open("com.palm.app.settings",inputs:[])}}
    func store()async throws {if device.kind == .samsung {try await home()} else {try await open("com.webos.app.discovery",inputs:[])}}
    func sources()async throws {if device.kind == .samsung {try await standard?.samsungKey("KEY_SOURCE")}}
    func setVolume(_ n:Int)async throws {if device.kind == .rootedLG {_ = try await luna("com.webos.audio/setVolume",["volume":n])} else {_ = try await standard?.request("audio/setVolume",["volume":n])}}
    func mute(_ value:Bool)async throws {if device.kind == .rootedLG {_ = try await luna("com.webos.audio/setMuted",["muted":value])} else if device.kind == .lg {_ = try await standard?.request("audio/setMute",["mute":value])} else {try await standard?.samsungKey("KEY_MUTE")}}
    func off()async throws {if device.kind == .rootedLG {_ = try await luna("com.webos.service.tvpower/power/powerOff",["reason":"remoteKey"])} else {try await standard?.powerOff();standard?.close()}}
    func wake()async throws {
        if !device.mac.isEmpty {try TVTransport.wake(config:device.config)}
        if device.kind == .rootedLG {_ = try? await luna("com.webos.service.tvpower/power/powerOn",["reason":"remoteKey"])}
        else if device.mac.isEmpty {throw ControlError.message("Voeg het MAC-adres van deze tv toe bij Televisies om hem uit stand-by te wekken.")}
    }
}
