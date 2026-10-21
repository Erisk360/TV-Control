import SwiftUI
import AppKit

#if !TV_TEST
#if CONTROL_CENTER_ONLY
@main struct ThuisControlCenterApp: App {
    @NSApplicationDelegateAdaptor(ControlDelegate.self) private var delegate
    var body: some Scene {
        // The companion owns the menu-bar panel and deliberately has no main
        // window. It therefore remains alive when the full Control app quits.
        Settings { EmptyView() }
    }
}
#else
@main struct ThuisControlApp: App {
    @NSApplicationDelegateAdaptor(ControlDelegate.self) private var delegate
    var body: some Scene {
        Window("Thuis Control", id: "main") {
            MainScene(delegate:delegate)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width:980,height:820)
        .commands { CommandGroup(after:.newItem) {Button("Ververs tv") {Task {await delegate.model.refresh(includeApps:true)}}.keyboardShortcut("r");Button("Open Thuis op tv") {delegate.model.home()}.keyboardShortcut("h",modifiers:[.command,.shift])} }
    }
}
#endif
final class FloatingControlPanel:NSPanel {
    override var canBecomeKey:Bool {true}
    override var canBecomeMain:Bool {false}
}
@MainActor final class ControlDelegate:NSObject,NSApplicationDelegate {
    let model=TVModel()
    private var item:NSStatusItem?
    private var panel:FloatingControlPanel?
    private var outsideMonitor:Any?
    private var localMonitor:Any?
    private var trackingMenu=false
    var showWindow:(()->Void)?
    func applicationDidFinishLaunching(_ notification:Notification) {
        let item=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength);self.item=item
        if let button=item.button {
            let image=NSImage(systemSymbolName:"slider.horizontal.3",accessibilityDescription:"Thuis Control");image?.isTemplate=true
            button.image=image;button.toolTip="Thuis Control";button.setAccessibilityLabel("Thuis Control");button.target=self;button.action=#selector(togglePanel)
        }
        let panel=FloatingControlPanel(contentRect:NSRect(x:0,y:0,width:300,height:470),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isReleasedWhenClosed=false;panel.hidesOnDeactivate=false;panel.isFloatingPanel=true;panel.level = .popUpMenu
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.transient,.ignoresCycle]
        panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=true;panel.title="Thuis bedieningspaneel"
        panel.contentViewController=NSHostingController(rootView:MenuCenter(model:model,onOpenWindow:{[weak self] in
            self?.closePanel()
            if let open=self?.showWindow { open() }
            else { self?.openFullControl() }
        },onSizeChange:{[weak self] height in self?.sizePanel(height)}).preferredColorScheme(.dark))
        self.panel=panel
        NotificationCenter.default.addObserver(self,selector:#selector(menuBegan),name:NSMenu.didBeginTrackingNotification,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(menuEnded),name:NSMenu.didEndTrackingNotification,object:nil)
        outsideMonitor=NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) {[weak self] _ in Task {@MainActor in self?.closeIfOutside()}}
        localMonitor=NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) {[weak self] event in self?.closeIfOutside();return event}
    }
    private func sizePanel(_ height:CGFloat) {
        guard let panel else {return}
        let screen=item?.button?.window?.screen ?? NSScreen.main
        panel.setContentSize(NSSize(width:300,height:min(height,(screen?.visibleFrame.height ?? 800)-24)))
        positionPanel()
    }
    private func positionPanel() {
        guard let panel,let button=item?.button,let window=button.window,let screen=window.screen else {return}
        let rect=window.convertToScreen(button.convert(button.bounds,to:nil));let visible=screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x:min(max(visible.minX+8,rect.maxX-panel.frame.width),visible.maxX-panel.frame.width-8),y:visible.maxY-panel.frame.height-8))
    }
    @objc private func togglePanel() {
        guard let panel else {return}
        if panel.isVisible {closePanel()} else {positionPanel();panel.orderFrontRegardless();panel.makeKey();Task {await model.refresh(quiet:true)}}
    }
    private func closeIfOutside() {
        guard !trackingMenu,let panel,panel.isVisible,!panel.frame.contains(NSEvent.mouseLocation) else {return}
        if let button=item?.button,let window=button.window,window.convertToScreen(button.convert(button.bounds,to:nil)).contains(NSEvent.mouseLocation) {return}
        closePanel()
    }
    @objc private func menuBegan(){trackingMenu=true}
    @objc private func menuEnded(){trackingMenu=false}
    private func closePanel() {panel?.orderOut(nil)}
    private func openFullControl() {
        guard let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"nl.dextiny.thuis.control") else {return}
        NSWorkspace.shared.openApplication(at:url,configuration:.init())
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {false}
    func applicationWillTerminate(_ notification:Notification) {NotificationCenter.default.removeObserver(self);if let outsideMonitor {NSEvent.removeMonitor(outsideMonitor)};if let localMonitor {NSEvent.removeMonitor(localMonitor)};if let item {NSStatusBar.system.removeStatusItem(item)}}
}
struct MainScene:View {
    let delegate:ControlDelegate
    @Environment(\.openWindow) private var openWindow
    var body:some View {MainWindow(model:delegate.model).preferredColorScheme(.dark).onAppear {let open=openWindow;delegate.showWindow={open(id:"main");NSApp.activate(ignoringOtherApps:true)}}}
}
#endif

private let quiet = Color.white.opacity(0.52)
private let blue = Color(red:0.25,green:0.56,blue:1)

struct GlassSurface: ViewModifier {
    var radius: CGFloat = 24
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0,*) {
            content.glassEffect(.clear.interactive(),in:RoundedRectangle(cornerRadius:radius,style:.continuous))
        } else {content.background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:radius,style:.continuous))}
    }
}
extension View { func glassTile(_ radius:CGFloat = 24) -> some View { modifier(GlassSurface(radius:radius)) } }
struct SoftPress: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration) -> some View { configuration.label.contentShape(Rectangle()).opacity(!enabled ? 0.35 : configuration.isPressed ? 0.7 : 1).scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1).animation(reduceMotion ? nil : .easeOut(duration:0.16),value:configuration.isPressed) }
}
struct RoundControl: View {
    let symbol:String; let title:String; var selected = false; var size:CGFloat = 38; var action:()->Void
    @ViewState private var hover = false
    var body: some View {
        Button(action:action) { Image(systemName:symbol).font(.system(size:size*0.40,weight:.medium)).frame(width:size,height:size).foregroundStyle(selected ? .white : .white.opacity(0.88)).background(selected ? blue : .white.opacity(hover ? 0.16 : 0.08),in:Circle()).overlay(Circle().strokeBorder(.white.opacity(0.10),lineWidth:0.6)) }.buttonStyle(SoftPress()).onHover {hover=$0}.help(title).accessibilityLabel(title)
    }
}
struct PanelBackground: NSViewRepresentable {
    func makeNSView(context:Context) -> NSVisualEffectView { let v=NSVisualEffectView();v.material = .hudWindow;v.blendingMode = .behindWindow;v.state = .active;DispatchQueue.main.async {if v.window?.styleMask.contains(.titled) == true {v.window?.isMovableByWindowBackground=true;v.window?.backgroundColor = .clear}};return v }
    func updateNSView(_ nsView:NSVisualEffectView,context:Context) {}
}
struct WindowAppearance:NSViewRepresentable {
    final class Attachment:NSView,NSWindowDelegate {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else {return}
            window.isOpaque=false;window.backgroundColor = .clear;window.titlebarAppearsTransparent=true
            window.delegate=self
        }
        func windowShouldClose(_ sender:NSWindow)->Bool {
            // Closing the main window keeps the menu-bar control center alive.
            sender.orderOut(nil)
            return false
        }
    }
    func makeNSView(context:Context)->Attachment {Attachment()}
    func updateNSView(_ view:Attachment,context:Context) {}
}
struct Backdrop: View {
    @ViewBuilder var body: some View {
        if #available(macOS 26.0,*) {Color.clear.glassEffect(.regular,in:RoundedRectangle(cornerRadius:28,style:.continuous)).ignoresSafeArea()}
        else {PanelBackground().ignoresSafeArea()}
    }
}
struct SyncLoop: ViewModifier {
    @ObservedObject var model:TVModel
    func body(content:Content) -> some View { content.task {
        await model.refresh(includeApps:true,quiet:true)
        while !Task.isCancelled { do {try await Task.sleep(for:.seconds(5))} catch {return}; if !model.changingPower {await model.refresh(quiet:true)} }
    } }
}
struct StatusLine: View {
    @ObservedObject var model:TVModel
    var body: some View { HStack(spacing:6) { Circle().fill(model.active ? Color.green : model.power.contains("Standby") ? Color.orange : .gray).frame(width:5,height:5);Text(model.onlineLabel).font(.system(size:11,weight:.medium)).foregroundStyle(quiet) } }
}
struct Feedback: View {
    @ObservedObject var model:TVModel
    var body: some View {
        if let error=model.error { HStack(alignment:.top,spacing:9) {Image(systemName:"exclamationmark.circle.fill").foregroundStyle(.orange);Text(error).font(.system(size:12)).fixedSize(horizontal:false,vertical:true);Spacer(minLength:0);Button {model.error=nil} label:{Image(systemName:"xmark").font(.system(size:10,weight:.bold))}.buttonStyle(.plain).help("Melding sluiten") }.padding(14).background(.orange.opacity(0.12),in:RoundedRectangle(cornerRadius:16)) }
    }
}
struct MainWindow: View {
    @ObservedObject var model:TVModel
    
    @ViewState private var tab = "Apps"
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Image(systemName:"slider.horizontal.3").font(.system(size:20,weight:.semibold)).foregroundStyle(.white.opacity(0.85))
                VStack(alignment:.leading,spacing:2) {Text("Thuis").font(.system(size:22,weight:.semibold));Text("BEDIENINGSPANEEL").font(.system(size:9,weight:.semibold)).tracking(1.7).foregroundStyle(quiet)}
                Spacer()
                StatusLine(model:model).padding(.trailing,6)
                RoundControl(symbol:"arrow.clockwise",title:"Tv en apps verversen") {Task {await model.refresh(includeApps:true)}}.disabled(model.refreshing)
                RoundControl(symbol:"gearshape",title:"Verbinding en instellingen") {model.showDevices=true}
            }.padding(.leading,80).padding(.trailing,24).padding(.top,18).padding(.bottom,22)
            VStack(spacing:12) {
                Feedback(model:model).padding(.horizontal,24)
                GeometryReader { geometry in
                    if geometry.size.width >= 800 {
                        HStack(alignment:.top,spacing:24) {
                            ScrollView {ControlStack(model:model,showInputs:{tab="Ingangen"},onManage:{model.showDevices=true}).padding(.bottom,12)}.scrollIndicators(.hidden).frame(width:324)
                            ScrollView {AppLibrary(model:model,tab:$tab).padding(.bottom,24)}.scrollIndicators(.hidden)
                        }.padding(.horizontal,24)
                    } else {
                        ScrollView {VStack(spacing:28) {ControlStack(model:model,showInputs:{tab="Ingangen"},onManage:{model.showDevices=true}).frame(maxWidth:440);AppLibrary(model:model,tab:$tab)}.frame(maxWidth:.infinity).padding(.horizontal,24).padding(.bottom,24)}
                    }
                }
            }
            HStack(spacing:6) {Image(systemName:model.commandCount>0 ? "antenna.radiowaves.left.and.right" : "checkmark.circle");Text(model.message).lineLimit(1);Spacer();Text(model.selected.model.isEmpty ? model.selected.kind.title : model.selected.model).foregroundStyle(.white.opacity(0.3)) }.font(.system(size:10)).foregroundStyle(quiet).padding(.horizontal,28).padding(.vertical,12)
        }.background(Backdrop()).background(WindowAppearance()).frame(minWidth:510,minHeight:640)
        .sheet(isPresented:$model.showDevices) {TVDevicesView(model:model)}
        .modifier(SyncLoop(model:model))
    }
}
struct ControlStack: View {
    @ObservedObject var model:TVModel
    var compact=false
    var showInputs:()->Void
    var onManage:()->Void = {}
    var onRemoteExpansion:((Bool)->Void)? = nil
    @ViewState private var remoteExpanded=false
    var body: some View {
        VStack(spacing:compact ? 8 : 12) {
            device
            nowOpen
            VolumeTile(model:model,compact:compact)
            if compact {
                Button {withAnimation(.easeInOut(duration:0.18)) {remoteExpanded.toggle();onRemoteExpansion?(remoteExpanded)}} label:{HStack(spacing:12) {Image(systemName:"appletvremote.gen4").font(.system(size:18));Text("Afstandsbediening").font(.system(size:13,weight:.semibold));Spacer();Image(systemName:remoteExpanded ? "chevron.up" : "chevron.down").font(.system(size:10,weight:.semibold)).foregroundStyle(quiet)}.padding(10).glassTile(16)}.buttonStyle(SoftPress()).help("Afstandsbediening uitklappen")
                if remoteExpanded {RemoteTile(model:model,compact:true)}
            } else {RemoteTile(model:model)}
            HStack(spacing:10) {
                shortcut("cable.connector","Ingangen",action:showInputs)
                shortcut("gearshape","Instellingen") {model.openSettings()}
                shortcut("bag",model.isSamsung ? "Smart Hub" : "Appwinkel") {model.openStore()}
            }
        }
    }
    private var device: some View {
        HStack(spacing:12) {
            Image(systemName:"tv").font(.system(size:compact ? 19 : 24,weight:.regular)).frame(width:compact ? 32 : 46,height:compact ? 32 : 46).background(blue.opacity(0.22),in:RoundedRectangle(cornerRadius:15)).foregroundStyle(Color(red:0.58,green:0.77,blue:1))
            VStack(alignment:.leading,spacing:5) {
                Menu {ForEach(model.devices) {device in Button {model.select(device.id)} label:{Text(device.name+" · "+device.kind.title)}};Divider();Button("Televisies beheren…",systemImage:"plus") {onManage()}} label:{HStack(spacing:5) {Text(model.selected.name).font(.system(size:compact ? 14 : 16,weight:.semibold)).lineLimit(1);Image(systemName:"chevron.down").font(.system(size:9,weight:.semibold))}}.menuStyle(.borderlessButton).menuIndicator(.hidden).disabled(model.busy)
                StatusLine(model:model)
            }

            Spacer(minLength:4)
            if model.isSamsung && !model.active {
                Button {model.pair()} label:{Label("Verbind",systemImage:"link")}
                    .buttonStyle(.borderedProminent)
                    .controlSize(compact ? .small : .regular)
                    .disabled(model.busy)
                    .help("Maak één keer verbinding met de Samsung")
            }
            RoundControl(symbol:"power",title:model.active ? "Tv in stand-by zetten" : "Tv aanzetten",selected:model.active,size:compact ? 34 : 44) {if model.active {model.turnOff()} else {model.turnOn()}}.disabled(model.changingPower)
        }.padding(compact ? 10 : 16).glassTile(compact ? 18 : 24)
    }
    private var nowOpen: some View {
        HStack(spacing:12) {
            AppArtwork(app:model.currentApp,image:model.images[model.currentApp.id],size:compact ? 30 : 46)
            VStack(alignment:.leading,spacing:5) {Text(model.active ? model.isSamsung ? "LAATST GEOPEND" : "NU OP JE TV" : "JE TV").font(.system(size:9,weight:.semibold)).tracking(1.2).foregroundStyle(quiet);Text(model.active ? model.appTitle : model.paired ? "Even pauze" : "Koppel je tv").font(.system(size:compact ? 13 : 15,weight:.semibold)).lineLimit(1)}
            Spacer(minLength:0)
            if model.selected.kind == .lg {HStack(spacing:4) {RoundControl(symbol:"play.fill",title:"Afspelen",size:28) {model.key(207)};RoundControl(symbol:"pause.fill",title:"Pauzeren",size:28) {model.key(119)}}.disabled(!model.active)} else {RoundControl(symbol:"playpause.fill",title:"Afspelen of pauzeren",size:compact ? 28 : 34) {model.key(164)}.disabled(!model.active)}
        }.padding(compact ? 10 : 16).glassTile(compact ? 18 : 24).task(id:model.currentApp.id) {await model.loadIcon(model.currentApp)}
    }
    private func shortcut(_ icon:String,_ title:String,action:@escaping()->Void) -> some View {
        Button(action:action) {VStack(spacing:compact ? 5 : 8) {Image(systemName:icon).font(.system(size:compact ? 16 : 19,weight:.regular));Text(title).font(.system(size:10,weight:.medium)).lineLimit(1)}.frame(maxWidth:.infinity).frame(height:compact ? 48 : 70).glassTile(compact ? 16 : 21)}.buttonStyle(SoftPress()).disabled(!model.active).help(title).accessibilityLabel(title)
    }
}
struct VolumeTile: View {
    @ObservedObject var model:TVModel
    var compact=false
    var body: some View {
        VStack(alignment:.leading,spacing:compact ? 7 : 12) {
            HStack {Text("Geluid").font(.system(size:13,weight:.semibold));Spacer();Text(model.isSamsung ? "Tv-volume" : model.muted ? "Gedempt" : "\(Int(model.volume))%").font(.system(size:11,weight:.medium)).monospacedDigit().foregroundStyle(quiet)}
            HStack(spacing:10) {
                Button {model.toggleMute()} label:{Image(systemName:model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size:17)).frame(width:28,height:34).foregroundStyle(model.muted ? blue : .white)}.buttonStyle(SoftPress()).help(model.muted ? "Geluid aanzetten" : "Geluid dempen").accessibilityLabel(model.muted ? "Geluid aanzetten" : "Geluid dempen")
                if model.supportsVolumeLevel {CapsuleSlider(value:$model.volume,enabled:model.active,onChange:{model.setVolume($0)},onEditing:{model.adjustingVolume=$0})} else {Spacer();RoundControl(symbol:"minus",title:"Volume lager",size:32) {model.key(114)};RoundControl(symbol:"plus",title:"Volume hoger",size:32) {model.key(115)}}
            }
        }.padding(compact ? 10 : 16).glassTile(compact ? 18 : 24).disabled(!model.active)
    }
}
struct CapsuleSlider: View {
    @Binding var value:Double
    var enabled:Bool
    var onChange:(Double)->Void
    var onEditing:(Bool)->Void
    @ViewState private var dragging=false
    var body: some View {
        GeometryReader {geometry in
            ZStack(alignment:.leading) {
                Capsule().fill(.black.opacity(0.20))
                Capsule().fill(LinearGradient(colors:[.white.opacity(0.75),.white],startPoint:.leading,endPoint:.trailing)).frame(width:max(29,geometry.size.width*value/100))
                Capsule().fill(.black.opacity(0.18)).frame(width:3,height:13).offset(x:max(14,geometry.size.width*value/100-13))
            }.frame(height:30).contentShape(Capsule())
                .gesture(DragGesture(minimumDistance:0).onChanged {event in guard enabled else {return};if !dragging {dragging=true;onEditing(true)};value=min(100,max(0,event.location.x/geometry.size.width*100)).rounded();onChange(value)}.onEnded {_ in dragging=false;onEditing(false);onChange(value)})
        }.frame(height:30).accessibilityElement().accessibilityLabel("Tv-volume").accessibilityValue("\(Int(value)) procent").accessibilityAdjustableAction {direction in switch direction {case .increment:onChange(min(100,value+1));case .decrement:onChange(max(0,value-1));@unknown default:break} }
    }
}
struct RemoteTile: View {
    @ObservedObject var model:TVModel
    var compact=false
    var body: some View {
        VStack(spacing:10) {
            HStack {Text("Afstandsbediening").font(.system(size:13,weight:.semibold));Spacer();Image(systemName:"keyboard").font(.system(size:12)).foregroundStyle(quiet).help("Pijltjes: navigeren · Enter: OK · Escape: terug · Spatie: pauze")}
            ZStack {
                Circle().fill(.black.opacity(0.15)).overlay(Circle().strokeBorder(.white.opacity(0.07),lineWidth:0.8))
                direction("chevron.up","Omhoog",103).offset(y:compact ? -51 : -64)
                direction("chevron.down","Omlaag",108).offset(y:compact ? 51 : 64)
                direction("chevron.left","Links",105).offset(x:compact ? -51 : -64)
                direction("chevron.right","Rechts",106).offset(x:compact ? 51 : 64)
                Button {model.key(28)} label:{Text("OK").font(.system(size:15,weight:.semibold)).frame(width:compact ? 58 : 70,height:compact ? 58 : 70).background(LinearGradient(colors:[.white.opacity(0.13),.white.opacity(0.04)],startPoint:.top,endPoint:.bottom),in:Circle()).overlay(Circle().strokeBorder(.white.opacity(0.15),lineWidth:0.8)).shadow(color:.black.opacity(0.12),radius:8,y:3)}.buttonStyle(SoftPress()).help("Bevestigen").accessibilityLabel("Bevestigen")
            }.frame(width:compact ? 154 : 186,height:compact ? 154 : 186)
            HStack(spacing:10) {
                Button {model.key(412)} label:{Label("Terug",systemImage:"chevron.backward").font(.system(size:12,weight:.medium)).frame(maxWidth:.infinity).frame(height:34).background(.white.opacity(0.06),in:Capsule())}.buttonStyle(SoftPress()).help("Terug")
                Button {model.home()} label:{Label("Thuis",systemImage:"house.fill").font(.system(size:12,weight:.medium)).frame(maxWidth:.infinity).frame(height:34).background(.white.opacity(0.06),in:Capsule())}.buttonStyle(SoftPress()).help("Thuis openen")
            }
        }.padding(compact ? 10 : 16).glassTile(compact ? 18 : 24).disabled(!model.active)
        .background(KeyboardMonitor(enabled:model.active) {code in switch code {case 123:model.key(105);case 124:model.key(106);case 125:model.key(108);case 126:model.key(103);case 36,76:model.key(28);case 49:model.key(164);case 53:model.key(412);default:break}})
    }
    private func direction(_ symbol:String,_ title:String,_ code:Int) -> some View {Button {model.key(code)} label:{Image(systemName:symbol).font(.system(size:16,weight:.medium)).frame(width:50,height:45).contentShape(Capsule())}.buttonStyle(SoftPress()).help(title).accessibilityLabel(title)}
}
struct AppArtwork: View {
    let app:TVApp
    var image:NSImage?
    var size:CGFloat=58
    private var icon:NSImage? {image ?? Bundle.main.url(forResource:app.title.lowercased()=="youtube" ? "youtube.leanback.v4" : app.id,withExtension:"png",subdirectory:"icons").flatMap {NSImage(contentsOf:$0)}}
    private var name:String {app.title.lowercased()}
    private var background:Color {
        if name == "netflix" || name.contains("apple tv") || app.id == "netflix" || app.id == "com.apple.appletv" {return .black}
        if name == "youtube" || app.id == "youtube.leanback.v4" {return .white}
        if name.contains("prime") {return Color(red:0.03,green:0.35,blue:0.62)}
        if name.contains("disney") {return Color(red:0.02,green:0.08,blue:0.30)}
        if name == "spotify" {return Color(red:0.11,green:0.74,blue:0.34)}
        return Color.white.opacity(0.075)
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius:size*0.23,style:.continuous).fill(background)
            if app.id == "netflix" || app.title.lowercased()=="netflix" {
                NetflixMark().frame(width:size*0.34,height:size*0.60)
            } else if app.id == "com.apple.appletv" || name.contains("apple tv") {
                HStack(spacing:1) {Image(systemName:"apple.logo").font(.system(size:size*0.32));Text("tv").font(.system(size:size*0.40,weight:.medium))}.foregroundStyle(.white)
            } else if name == "youtube" || app.id == "youtube.leanback.v4" {
                RoundedRectangle(cornerRadius:size*0.13,style:.continuous).fill(Color(red:0.96,green:0.05,blue:0.09)).frame(width:size*0.62,height:size*0.44).overlay(Image(systemName:"play.fill").font(.system(size:size*0.21,weight:.bold)).foregroundStyle(.white))
            } else if name.contains("prime") {
                VStack(spacing:-size*0.03) {Text("prime").font(.system(size:size*0.25,weight:.bold)).foregroundStyle(.white);Text("video").font(.system(size:size*0.16,weight:.medium)).foregroundStyle(.white.opacity(0.92));Image(systemName:"smile").font(.system(size:size*0.22,weight:.medium)).foregroundStyle(Color(red:0.1,green:0.78,blue:1))}
            } else if name.contains("disney") {
                ZStack {Text("Disney").font(.system(size:size*0.23,weight:.medium,design:.serif)).italic().foregroundStyle(.white);Text("+").font(.system(size:size*0.18,weight:.bold)).foregroundStyle(.white).offset(x:size*0.27,y:-size*0.08);Capsule().stroke(Color(red:0.35,green:0.73,blue:1),lineWidth:max(1,size*0.018)).frame(width:size*0.70,height:size*0.23).offset(y:-size*0.16)}
            } else if name == "spotify" {
                Circle().fill(.black).frame(width:size*0.61,height:size*0.61).overlay(VStack(spacing:size*0.045) {ForEach([0.46,0.39,0.32],id:\.self) {width in Capsule().fill(Color(red:0.11,green:0.74,blue:0.34)).frame(width:size*width,height:max(1.5,size*0.045)).rotationEffect(.degrees(8))}}.offset(y:-size*0.015))
            } else if let icon {Image(nsImage:icon).resizable().scaledToFit().padding(size*0.10)} else {Image(systemName:["nl.dextiny.thuis","__home"].contains(app.id) ? "house.fill" : app.id.contains("settings") ? "gearshape.fill" : app.id.contains("hdmi") ? "cable.connector" : "app.fill").font(.system(size:size*0.44,weight:.regular)).foregroundStyle(app.id == "nl.dextiny.thuis" ? Color(red:0.69,green:0.70,blue:1) : .white.opacity(0.8))}
        }.frame(width:size,height:size).clipShape(RoundedRectangle(cornerRadius:size*0.23,style:.continuous)).overlay(RoundedRectangle(cornerRadius:size*0.23,style:.continuous).strokeBorder(.white.opacity(0.1),lineWidth:0.6))
    }
}
struct AppLibrary: View {
    @ObservedObject var model:TVModel
    @Binding var tab:String
    @ViewState private var search=""
    @ViewState private var editing=false
    @ViewState private var addingApp=false
    private var list:[TVApp] {model.library.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }}
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            HStack {Text("Jouw televisie").font(.system(size:25,weight:.semibold));Spacer();Text(model.selected.kind.title).font(.system(size:10,weight:.medium)).foregroundStyle(quiet).padding(.horizontal,10).padding(.vertical,6).background(.white.opacity(0.05),in:Capsule())}
            Picker("Weergave",selection:$tab) {Text("Apps").tag("Apps");Text("Ingangen").tag("Ingangen")}.pickerStyle(.segmented).labelsHidden().controlSize(.large)
            if tab == "Ingangen" {inputs.transition(.opacity)} else {apps.transition(.opacity)}
        }.animation(.easeInOut(duration:0.18),value:tab).sheet(isPresented:$addingApp) {ManualTVAppSheet(model:model)}
    }
    private var apps: some View {
        VStack(alignment:.leading,spacing:20) {
            HStack(spacing:9) {Image(systemName:"magnifyingglass").foregroundStyle(quiet);TextField("Zoek apps op je tv",text:$search).textFieldStyle(.plain).font(.system(size:13));if !search.isEmpty {Button {search=""} label:{Image(systemName:"xmark.circle.fill").foregroundStyle(quiet)}.buttonStyle(.plain)}}.padding(12).glassTile(15)
            if search.isEmpty && !model.pinnedApps.isEmpty {
                HStack {section("FAVORIETEN");Spacer();Button(editing ? "Gereed" : "Bewerk") {editing.toggle()}.font(.system(size:11,weight:.medium)).foregroundStyle(editing ? .white : quiet).buttonStyle(.plain)}
                LazyVGrid(columns:[GridItem(.adaptive(minimum:102),spacing:12)],spacing:12) {ForEach(model.pinnedApps) {app in AppTile(model:model,app:app,pinned:true,editing:editing)}}
                Rectangle().fill(.white.opacity(0.08)).frame(height:0.6)
            }
            HStack {section(search.isEmpty ? "ALLE APPS" : "ZOEKRESULTATEN");Spacer();if model.isSamsung {Button {addingApp=true} label:{Image(systemName:"plus")}.buttonStyle(.plain).help("App handmatig toevoegen")};Text("\(list.count)").font(.system(size:11)).foregroundStyle(quiet)}
            if let notice=model.notice {Text(notice).font(.system(size:11)).foregroundStyle(.secondary)}
            if list.isEmpty {
                VStack(spacing:10) {Image(systemName:search.isEmpty ? "tv" : "magnifyingglass").font(.system(size:28,weight:.light));Text(search.isEmpty ? "Zet je tv aan om apps te laden." : "Geen apps gevonden").font(.system(size:13))}.foregroundStyle(quiet).frame(maxWidth:.infinity).padding(.vertical,42)
            } else {
                LazyVGrid(columns:[GridItem(.adaptive(minimum:102),spacing:12)],spacing:12) {ForEach(list) {app in AppTile(model:model,app:app,pinned:model.favorites.contains(app.id),editing:editing)}}
            }
            if search.isEmpty {Text("Klik om te openen. Rechtsklik om favorieten te wijzigen.").font(.system(size:10)).foregroundStyle(.white.opacity(0.35)).padding(.top,2)}
        }
    }
    private var inputs: some View {
        VStack(alignment:.leading,spacing:12) {
            section("HDMI-INGANGEN")
            if model.isSamsung {Button("Bronnen op tv openen",systemImage:"cable.connector") {model.openSources()}.buttonStyle(.borderedProminent).disabled(!model.active);Text("Kies de ingang met de pijltjestoetsen van de afstandsbediening.").font(.system(size:11)).foregroundStyle(.secondary)}
            else if model.inputs.isEmpty {Text("Zet de tv aan en ververs om de ingangen te laden.").font(.callout).foregroundStyle(quiet).padding(.vertical,25)}
            ForEach(model.inputs) {input in
                Button {model.open(input.appId,title:input.label)} label:{HStack(spacing:14) {Image(systemName:"cable.connector").font(.system(size:24)).frame(width:46,height:46).background(.white.opacity(0.06),in:RoundedRectangle(cornerRadius:13));VStack(alignment:.leading,spacing:4) {Text(input.label).font(.system(size:14,weight:.semibold));Text(input.connected ? "Apparaat verbonden" : "Geen actief signaal").font(.system(size:11)).foregroundStyle(quiet)};Spacer();Image(systemName:model.foreground == input.appId ? "checkmark.circle.fill" : "chevron.right").font(.system(size:14)).foregroundStyle(model.foreground == input.appId ? blue : quiet)}.padding(16).glassTile(21)}.buttonStyle(SoftPress()).help(input.label).disabled(!model.active)
            }
        }
    }
    private func section(_ text:String) -> some View {Text(text).font(.system(size:9,weight:.semibold)).tracking(1.4).foregroundStyle(quiet)}
}
struct AppTile: View {
    @ObservedObject var model:TVModel
    let app:TVApp
    var pinned=false
    var editing=false
    @ViewState private var hovering=false
    var body: some View {
        Button {if editing {model.toggleFavorite(app.id)} else {model.open(app.id,title:app.title)}} label:{
            VStack(spacing:10) {
                ZStack(alignment:.topTrailing) {
                    AppArtwork(app:app,image:model.images[app.id],size:54)
                    if editing {Image(systemName:pinned ? "minus.circle.fill" : "plus.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white,pinned ? Color.gray : blue).font(.system(size:18)).offset(x:6,y:-6)}
                }
                Text(app.title).font(.system(size:11,weight:.medium)).lineLimit(1).frame(maxWidth:.infinity)
            }.padding(.vertical,16).padding(.horizontal,8).frame(maxWidth:.infinity).background(.white.opacity(hovering ? 0.105 : 0.035),in:RoundedRectangle(cornerRadius:21)).overlay(RoundedRectangle(cornerRadius:21).strokeBorder(model.foreground == app.id && model.active ? blue.opacity(0.65) : .white.opacity(hovering ? 0.18 : 0.07),lineWidth:0.8))
        }.buttonStyle(SoftPress()).onHover {hovering=$0}.disabled(!editing && !(model.active || model.isSamsung)).accessibilityLabel(editing ? (pinned ? "Verwijder favoriet " : "Maak favoriet ") + app.title : "Open \(app.title) op tv")
        .help("Open \(app.title) op tv")
        .contextMenu {Button(pinned ? "Verwijder uit favorieten" : "Voeg toe aan favorieten",systemImage:pinned ? "star.slash" : "star") {model.toggleFavorite(app.id)}}
        .task(id:app.id) {await model.loadIcon(app)}
    }
}
struct MenuCenter: View {
    @ObservedObject var model:TVModel
    var onOpenWindow:()->Void
    var onSizeChange:((CGFloat)->Void)? = nil
    @ViewState private var inputs=false
    @ViewState private var remoteExpanded=false
    var body: some View {
        ScrollView {
            VStack(spacing:8) {
                HStack {Text("Thuis").font(.system(size:16,weight:.semibold));Spacer();RoundControl(symbol:"arrow.up.left.and.arrow.down.right",title:"Open volledig bedieningspaneel",size:26) {onOpenWindow()}}.padding(.horizontal,3).padding(.bottom,3)
                Feedback(model:model)
                ControlStack(model:model,compact:true,showInputs:{inputs.toggle()},onManage:{model.showDevices=true;onOpenWindow()},onRemoteExpansion:{remoteExpanded=$0})
                if inputs && model.isSamsung {Button("Bronnen op tv openen") {model.openSources()}.buttonStyle(.bordered)}
                if inputs {ForEach(model.inputs) {input in Button(input.label) {model.open(input.appId,title:input.label)}.buttonStyle(.bordered).disabled(!model.active)}}
                HStack(spacing:12) {ForEach(Array(model.pinnedApps.prefix(4))) {app in Button {model.open(app.id,title:app.title)} label:{AppArtwork(app:app,image:model.images[app.id],size:32)}.buttonStyle(SoftPress()).help("Open \(app.title)").disabled(!model.active)}}.padding(.vertical,2)
                HStack {Button("Alle apps") {onOpenWindow()};Spacer();Button {Task {await model.refresh(includeApps:true)}} label:{Image(systemName:"arrow.clockwise")}.help("Verversen");Menu {Button("Sluit Thuis Control") {NSApp.terminate(nil)}} label:{Image(systemName:"ellipsis")}.menuStyle(.borderlessButton).fixedSize()}.font(.system(size:11,weight:.medium)).buttonStyle(.plain).foregroundStyle(quiet).padding(.horizontal,6)
            }.padding(10)
        }.frame(width:300,height:min(remoteExpanded || inputs ? 710 : 470,NSScreen.main.map {$0.visibleFrame.height - 60} ?? 740)).background(Backdrop()).clipShape(RoundedRectangle(cornerRadius:28)).modifier(SyncLoop(model:model)).onChange(of:remoteExpanded || inputs) {_,expanded in onSizeChange?(expanded ? 710 : 470)}
    }
}
// A window-scoped event monitor keeps arrows working after clicking buttons,
// without taking focus from search fields or connection settings.
struct KeyboardMonitor: NSViewRepresentable {
    var enabled:Bool
    let handler:(UInt16)->Void
    final class MonitorView:NSView {
        var enabled=false;var handler:((UInt16)->Void)?;var monitor:Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {NSEvent.removeMonitor(monitor);self.monitor=nil}
            guard window != nil else {return}
            monitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) {[weak self] event in
                guard let self,self.enabled,let window=self.window,event.window === window,window.attachedSheet == nil,!event.modifierFlags.contains(.command),!event.modifierFlags.contains(.control),!event.modifierFlags.contains(.option),!(window.firstResponder is NSTextView),[UInt16(123),124,125,126,36,76,49,53].contains(event.keyCode) else {return event}
                self.handler?(event.keyCode);return nil
            }
        }
        deinit {if let monitor {NSEvent.removeMonitor(monitor)}}
    }
    func makeNSView(context:Context) -> MonitorView {let view=MonitorView();view.enabled=enabled;view.handler=handler;return view}
    func updateNSView(_ view:MonitorView,context:Context) {view.enabled=enabled;view.handler=handler}
}
struct NetflixMark: View {
    var body: some View {
        GeometryReader { g in
            let w=g.size.width;let h=g.size.height
            ZStack {
                Path {p in p.move(to:.zero);p.addLines([CGPoint(x:w*0.32,y:0),CGPoint(x:w*0.32,y:h*0.95),CGPoint(x:0,y:h)])}.fill(Color(red:0.70,green:0.02,blue:0.05))
                Path {p in p.move(to:CGPoint(x:w*0.68,y:0));p.addLines([CGPoint(x:w,y:0),CGPoint(x:w,y:h),CGPoint(x:w*0.68,y:h*0.95)])}.fill(Color(red:0.70,green:0.02,blue:0.05))
                Path {p in p.move(to:.zero);p.addLines([CGPoint(x:w*0.32,y:0),CGPoint(x:w,y:h),CGPoint(x:w*0.68,y:h*0.95)])}.fill(Color(red:0.91,green:0.025,blue:0.08))
            }
        }
    }
}
