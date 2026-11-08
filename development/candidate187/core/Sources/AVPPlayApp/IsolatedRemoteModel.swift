import AppKit
import AVPPlayCore

final class RemotePanelCache {}

extension AppModel {
    var remoteGames: [Game] {
        var result = allGames
        let known = Set(result.map(\.id))
        result += localRecipes.filter { !known.contains($0.id) }.map { localGame(for: $0) }
        return result
    }

    func remoteStatus() -> RemoteStatus {
        let remoteJobs = jobs.prefix(40).map { job -> RemoteJob in
            let progress = copyProgress[job.id]
            let fraction: Double? = progress.flatMap { $0.total > 0 ? Double($0.done)/Double($0.total) : nil }
            let state: RemoteJob.State = job.id == runningJob ? .running : queued.contains(job.id) ? .queued
                : job.state == .finished ? .finished : job.state == .cancelled ? .cancelled : .stopped
            return RemoteJob(id:job.id,gameId:job.recipe.id,title:job.recipe.title,state:state,kind:.install,
                step:job.current?.title,stepIndex:job.completed.count,stepCount:job.steps.count,
                progress:fraction,progressText:progress?.activity,failure:job.failure,lastLine:nil,updated:job.updated,
                canResume:phase(of:job).canResume && (job.failureKind?.resumable ?? true),canCancel:phase(of:job).canCancel)
        }
        return RemoteStatus(deviceName:device?.name,deviceVia:nil,deviceProblem:deviceProblem,setupProblem:nil,
                            refreshing:refreshing,updatable:updatable.map(\.id),jobs:remoteJobs,notice:notice)
    }

    func remoteLibrary() -> RemoteLibrary {
        RemoteLibrary(games:remoteGames.map { game in
            let state: RemoteGame.OnDevice
            switch game.status.onDevice {
            case .unknown: state = .unknown
            case .notInstalled: state = .notInstalled
            case .current: state = .current
            default: state = .update
            }
            return RemoteGame(id:game.id,title:game.recipe.title,trust:.community,onDevice:state,
                downloaded:game.status.stockComplete,owned:nil,source:nil,busy:isBusy(game.id),
                installBlocker:blocker(for:game),canDownload:false,downloadBlocker:"Use a per-game action on this Mac.",
                downloadSize:nil,storeBytes:game.storeBytes,mixedReality:game.mixedReality,handTracking:false,
                favourite:false,coverKey:remoteCoverKey(game),builtWith:game.status.builtWith.map { "Klepton \($0.toolchain)" })
        },filters:[],onlineCatalog:onlineCatalog,horizonPlus:false)
    }

    func remoteCoverKey(_ game: Game) -> String? { game.cover == nil ? nil : "isolated-\(game.id)" }
    func remoteStoreCoverId(_ game: Game) -> String? { nil }
    func remotePanelOpened(_ id: String) { /* Reading a remote panel never starts purchase/fetch/build. */ }

    func remotePanel(_ id: String, cache: RemotePanelCache) -> RemotePanel? {
        if id == "settings" {
            return RemotePanel(id:id,sections:[RemoteSection(id:"controllers",title:"Surreal Touch",items:[
                RemoteItem(id:"surrealSupport",kind:.toggle,title:"Support in future builds",on:surrealSupport),
                RemoteItem(id:"controller",kind:.choice,title:"Initial controller",value:controllerMode.rawValue,
                    choices:ControllerMode.allCases.map { RemoteChoice(id:$0.rawValue,title:$0.title) }),
                RemoteItem(id:"frameGeneration",kind:.choice,title:"Default Frame Generation",value:defaultFrameGeneration.rawValue,
                    choices:FrameGeneration.allCases.map { RemoteChoice(id:$0.rawValue,title:$0.title) })])])
        }
        guard id.hasPrefix("game:"), let game=remoteGames.first(where: { "game:"+$0.id==id }) else { return nil }
        let options=options(for:game), runtime=toolchain(for:game)
        let settings=[RemoteItem(id:"surrealSupport",kind:.choice,title:"Surreal Touch support (next build)",
                value:options.surrealSupport.map { $0 ? "on" : "off" } ?? "inherit",
                choices:[RemoteChoice(id:"inherit",title:"Use global (\(surrealSupport ? "on" : "off"))"),RemoteChoice(id:"on",title:"On for this game"),RemoteChoice(id:"off",title:"Off for this game")],enabled:runtime?.supportsRuntime824==true),
            RemoteItem(id:"controller",kind:.choice,title:"Initial controller (next build)",
                value:options.controllerMode?.rawValue ?? "inherit",
                choices:[RemoteChoice(id:"inherit",title:"Use global (\(controllerMode.title))")]+ControllerMode.allCases.map { RemoteChoice(id:$0.rawValue,title:$0.title) },enabled:runtime?.supportsRuntime824==true),
            RemoteItem(id:"frameGeneration",kind:.choice,title:"Frame generation override (next build)",
                value:options.frameGeneration?.rawValue ?? "inherit",
                choices:[RemoteChoice(id:"inherit",title:"Use global (\(defaultFrameGeneration.title))")]+FrameGeneration.allCases.map { RemoteChoice(id:$0.rawValue,title:$0.title) },enabled:runtime?.supportsRuntime824==true),
            RemoteItem(id:"coreMods",kind:.toggle,title:"Beat Saber mods (next build)",on:options.coreMods==true,
                       enabled:runtime?.coreModsProfile(for:game.recipe) != nil),
            RemoteItem(id:"surrealSDK",kind:.choice,title:"Surreal backend (next build)",
                value:options.surrealSDK?.rawValue ?? "inherit",
                choices:[RemoteChoice(id:"inherit",title:"Use global (verified SDK)"),RemoteChoice(id:"verified",title:"Verified SDK"),RemoteChoice(id:"bluetooth",title:"Bluetooth fallback")],
                enabled:runtime?.supportsRuntime824==true)]
        return RemotePanel(id:id,sections:[RemoteSection(id:"runtime",title:game.recipe.title,
            footer:"Changes require a future build explicitly authorized on the Mac. Existing games and saves are unchanged.",items:settings)])
    }

    func performIsolatedRemote(_ request: RemoteRequest, confirmation: ((String)->Bool)? = nil) -> String? {
        func confirm(_ text:String) -> Bool {
            if let confirmation { return confirmation(text) }
            AppDelegate.openMain?();NSApp.setActivationPolicy(.regular);NSApp.activate(ignoringOtherApps:true)
            let alert=NSAlert();alert.messageText="AVP Play Remote Isolado";alert.informativeText=text
            alert.addButton(withTitle:"Autorizar no Mac");alert.addButton(withTitle:"Cancelar")
            return alert.runModal() == .alertFirstButtonReturn
        }
        switch request {
        case .refresh: refresh()
        case .panelAction(let panel,let item,let value):
            guard confirm("Alterar \(item) para \(value ?? "") nas opções futuras? Nenhum jogo será reconstruído agora.") else { return "Cancelled on Mac." }
            if panel == "settings" {
                if item == "surrealSupport",value=="1" || value=="0" { surrealSupport=value=="1" }
                else if item == "controller",let mode=value.flatMap(ControllerMode.init(rawValue:)) { controllerMode=mode }
                else if item == "frameGeneration",let mode=value.flatMap(FrameGeneration.init(rawValue:)) { defaultFrameGeneration=mode }
                else { return "Unsupported setting." }
            } else {
                guard let game=remoteGames.first(where: { "game:"+$0.id==panel }) else { return "Unknown game." }
                var options=options(for:game)
                switch item {
                case "surrealSupport":
                    if value=="inherit" { options.surrealSupport=nil }
                    else if value=="on" { options.surrealSupport=true }
                    else if value=="off" { options.surrealSupport=false }
                    else { return "Invalid Surreal Touch support override." }
                case "controller":
                    if value=="inherit" { options.controllerMode=nil }
                    else if let mode=value.flatMap(ControllerMode.init(rawValue:)) { options.controllerMode=mode }
                    else { return "Invalid controller override." }
                case "frameGeneration":
                    guard toolchain(for:game)?.supportsRuntime824==true else { return "Unsupported runtime." }
                    if value=="inherit" { options.frameGeneration=nil }
                    else if let mode=value.flatMap(FrameGeneration.init(rawValue:)) { options.frameGeneration=mode }
                    else { return "Invalid frame generation override." }
                case "coreMods":
                    guard value=="0" || (value=="1" && toolchain(for:game)?.coreModsProfile(for:game.recipe) != nil) else { return "No compatible mod profile." }
                    options.coreMods=value=="1"
                case "surrealSDK":
                    if value=="inherit" { options.surrealSDK=nil }
                    else if let mode=value.flatMap(SurrealSDKPolicy.init(rawValue:)) { options.surrealSDK=mode }
                    else { return "Invalid backend." }
                default:return "Unsupported setting."
                }
                setOptions(options,for:game)
            }
        case .resume(let id),.cancel(let id):
            guard let job=jobs.first(where:{$0.id==id}) else { return "Unknown job." }
            guard confirm("\(request): \(job.recipe.title). Usar as validações normais do Isolado?") else { return "Cancelled on Mac." }
            if case .resume = request { resume(job) } else { cancel(job) }
        case .install(let id),.download(let id):
            guard let game=remoteGames.first(where:{$0.id==id}) else { return "Unknown game." }
            guard confirm("\(request): \(game.recipe.title). Prosseguir usando os controles de identidade e conteúdo existentes?") else { return "Cancelled on Mac." }
            if case .download = request {
                if let problem=downloadBlocker(for:game) { return problem };download(game)
            } else if localRecipes.contains(where:{$0.id==id}) {
                guard selectedLocalRecipeID==id,let variant=localImport.variantID else { return "Select and validate an exact local APK variant on the Mac first." }
                guard let selected = localVariantStore.variants(for: game.recipe).first(where: { $0.id == variant }),
                      authorizeForLocalAction(selected,recipe:game.recipe) else { return "Local authorization missing." }
                installLocalAPKVariant(game,id:variant)
            } else {
                if let problem=blocker(for:game) { return problem };install(game)
            }
        case .updateAll: return "Mass updates are disabled in the isolated Remote. Choose one game and authorize on the Mac."
        case .clearJobs: return "Job deletion is disabled in the isolated Remote."
        default:return "Unsupported action."
        }
        return nil
    }
}
