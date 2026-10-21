import SwiftUI

struct TVDevicesView:View {
    @ObservedObject var model:TVModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var editor:TVDevice?
    @ViewState private var adding=false
    @ViewState private var removing:TVDevice?
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {VStack(alignment:.leading,spacing:5) {Text("Televisies").font(.system(size:25,weight:.semibold));Text("Jouw schermen. Eén bedieningspaneel.").font(.system(size:12)).foregroundStyle(.secondary)};Spacer();RoundControl(symbol:"xmark",title:"Sluiten",size:32) {dismiss()}}
            Feedback(model:model)
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    ForEach(model.devices) {device in
                        VStack(alignment:.leading,spacing:12) {
                            HStack(spacing:12) {Image(systemName:"tv").font(.system(size:22)).frame(width:44,height:44).background(.white.opacity(0.06),in:RoundedRectangle(cornerRadius:13));Button {model.select(device.id)} label:{VStack(alignment:.leading,spacing:4) {HStack {Text(device.name).font(.system(size:14,weight:.semibold));if device.id==model.selectedID {Image(systemName:"checkmark.circle.fill").foregroundStyle(.blue)}};Text("\(device.kind.title) · \(device.host)").font(.system(size:11)).foregroundStyle(.secondary)}}.buttonStyle(.plain).disabled(model.busy);Spacer();Button {editor=device} label:{Image(systemName:"pencil")}.buttonStyle(.plain).help("Tv wijzigen");if model.devices.count>1 {Button {removing=device} label:{Image(systemName:"minus.circle")}.buttonStyle(.plain).help("Tv verwijderen")}}
                            if device.id==model.selectedID && device.kind != .rootedLG {
                                HStack {if model.pairing {ProgressView().controlSize(.small);Text("Accepteer Thuis Control op je tv.").font(.system(size:11))} else {Text(model.paired ? "Gekoppeld" : "Nog niet gekoppeld").font(.system(size:11)).foregroundStyle(.secondary);Spacer();Button(model.paired ? "Opnieuw koppelen" : "Koppel met tv") {model.pair(replace:model.paired)}.buttonStyle(.borderedProminent).disabled(model.busy)}}
                            }
                        }.padding(15).glassTile(20)
                    }
                    HStack {Text("OP JE NETWERK").font(.system(size:10,weight:.semibold)).tracking(1.2).foregroundStyle(.secondary);Spacer();Button {model.discover()} label:{HStack {if model.scanning {ProgressView().controlSize(.mini)};Label(model.scanning ? "Zoeken…" : "Zoek televisies",systemImage:"antenna.radiowaves.left.and.right")}}.disabled(model.scanning)}.padding(.top,12)
                    ForEach(model.discovered.filter {found in !model.devices.contains(where:{$0.host==found.host})}) {found in
                        HStack {VStack(alignment:.leading,spacing:4) {Text(found.name).font(.system(size:13,weight:.semibold));Text("\(found.kind.title) · \(found.host)").font(.system(size:11)).foregroundStyle(.secondary)};Spacer();Button("Toevoegen") {model.add(found)}.buttonStyle(.bordered).disabled(model.busy)}.padding(14).glassTile(18)
                    }
                    if !model.discovered.isEmpty {let count=model.discovered.filter {found in model.devices.contains(where:{$0.host==found.host})}.count;if count>0 {Text("\(count) gevonden tv’s zijn al toegevoegd.").font(.system(size:11)).foregroundStyle(.secondary)}}
                    Text("Zet je tv aan en verbind hem met hetzelfde netwerk. Niet gevonden? Voeg hem handmatig toe met zijn IP-adres. Nieuwe tv’s vragen op het scherm om toestemming.").font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).padding(.vertical,5)
                }
            }
            HStack {Button("Tv handmatig toevoegen",systemImage:"plus") {adding=true}.buttonStyle(.borderedProminent);Spacer();Button("Gereed") {dismiss()}.keyboardShortcut(.defaultAction)}
        }.padding(26).frame(width:550,height:650).background(Backdrop())
        .sheet(isPresented:$adding) {TVDeviceEditor(model:model,device:nil)}
        .sheet(item:$editor) {device in TVDeviceEditor(model:model,device:device)}
        .confirmationDialog("\(removing?.name ?? "Tv") verwijderen uit Thuis Control?",isPresented:Binding(get:{removing != nil},set:{if !$0 {removing=nil}})) {Button("Verwijder tv",role:.destructive) {if let removing {model.remove(removing.id)};removing=nil};Button("Annuleren",role:.cancel) {removing=nil}}
    }
}
struct TVDeviceEditor:View {
    @ObservedObject var model:TVModel
    let device:TVDevice?
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name=""
    @ViewState private var host=""
    @ViewState private var mac=""
    @ViewState private var kind=TVDevice.Kind.lg
    @ViewState private var plain=false
    @ViewState private var validation:String?
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            Text(device == nil ? "Tv toevoegen" : "Tv wijzigen").font(.system(size:24,weight:.semibold))
            VStack(alignment:.leading,spacing:14) {
                TextField("Naam, bijvoorbeeld Slaapkamer",text:$name)
                if device?.kind != .rootedLG {Picker("Merk",selection:$kind) {Text("LG webOS").tag(TVDevice.Kind.lg);Text("Samsung Tizen").tag(TVDevice.Kind.samsung)}}
                TextField("IP-adres, bijvoorbeeld 192.168.1.90",text:$host)
                TextField("MAC-adres voor aanzetten (optioneel)",text:$mac)
                if device?.kind != .rootedLG {Toggle("Oudere tv: onbeveiligde lokale verbinding",isOn:$plain).font(.system(size:11))}
            }.textFieldStyle(.roundedBorder)
            Text("Het MAC-adres is nodig om de tv uit stand-by te wekken. LG webOS en Samsung Tizen koppelen rechtstreeks; er is geen ontwikkelaarsmodus of root-toegang nodig.").font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if let validation {Text(validation).font(.system(size:12)).foregroundStyle(.orange)}
            HStack {Button("Annuleren") {dismiss()}.keyboardShortcut(.cancelAction);Spacer();Button("Bewaar tv") {save()}.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)}
        }.padding(28).frame(width:460).background(Backdrop()).onAppear {if let device {name=device.name;host=device.host;mac=device.mac;kind=device.kind;plain=[3000,8001].contains(device.port)}}
    }
    private func save() {
        var next=device ?? TVDevice(name:"",host:"",kind:kind)
        next.name=name.trimmingCharacters(in:.whitespacesAndNewlines);next.host=host.trimmingCharacters(in:.whitespacesAndNewlines);next.mac=mac.trimmingCharacters(in:.whitespacesAndNewlines);next.kind=kind
        if kind != .rootedLG {next.port=plain ? (kind == .lg ? 3000 : 8001) : 0}
        guard next.valid else {validation="Controleer de naam, het IPv4-adres en het eventuele MAC-adres.";return}
        if device == nil {model.add(next)} else {model.update(next)}
        if model.error == nil {dismiss()} else {validation=model.error}
    }
}
struct ManualTVAppSheet:View {
    @ObservedObject var model:TVModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var title=""
    @ViewState private var id=""
    var body:some View {
        VStack(alignment:.leading,spacing:18) {Text("App toevoegen").font(.title2.weight(.semibold));Text("Gebruik de app-ID van de app op jouw tv. Samsung geeft op sommige modellen geen volledige applijst door.").font(.callout).foregroundStyle(.secondary);TextField("App-naam",text:$title);TextField("App-ID",text:$id);HStack {Button("Annuleren") {dismiss()};Spacer();Button("Voeg app toe") {model.addApp(id:id,title:title);dismiss()}.buttonStyle(.borderedProminent).disabled(title.trimmingCharacters(in:.whitespaces).isEmpty || id.trimmingCharacters(in:.whitespaces).isEmpty)}}.textFieldStyle(.roundedBorder).padding(26).frame(width:430).background(Backdrop())
    }
}
