import DockPinCore
import Foundation

let usage = """
dockpin-probe \(DockPinCore.version)

Uso:
  dockpin-probe displays                          Lista monitores (índice, UUID, frame). Solo lectura.
  dockpin-probe locate                            Dice en qué monitor está el Dock. Solo lectura.
  dockpin-probe relocate --to <uuid|índice> --once
                                                  UN intento acotado: MUEVE EL CURSOR. Requiere Accesibilidad.
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func describe(_ frame: CGRect) -> String {
    "x=\(Int(frame.minX)) y=\(Int(frame.minY)) w=\(Int(frame.width)) h=\(Int(frame.height))"
}

func printDisplays(_ displays: [DisplayInfo]) {
    if displays.isEmpty { print("(sin monitores activos)") }
    for (i, d) in displays.enumerated() {
        var tags: [String] = []
        if d.isMain { tags.append("principal") }
        if d.isBuiltin { tags.append("integrado") }
        if d.isAmbiguous { tags.append("AMBIGUO: UUID repetido") }
        let suffix = tags.isEmpty ? "" : "  [\(tags.joined(separator: ", "))]"
        print("[\(i)] \(d.identity.uuid)  \(describe(d.frame))  id=\(d.displayID)\(suffix)")
    }
}

func placementDescription(_ placement: DockPlacement, displays: [DisplayInfo]) -> String {
    switch placement {
    case let .onDisplay(identity):
        let index = displays.firstIndex { $0.identity == identity }.map { "[\($0)] " } ?? ""
        return "Dock en monitor \(index)\(identity.uuid)"
    case let .unknown(reason):
        return "Ubicación del Dock DESCONOCIDA (\(reason)); no implica que esté mal ubicado."
    }
}

func runLocate(_ displays: [DisplayInfo]) -> DockPlacement {
    DockLocator().locate(in: displays)
}

let args = Array(CommandLine.arguments.dropFirst())
let provider = SystemDisplayProvider()

switch args.first {
case "displays":
    printDisplays(provider.connectedDisplays())

case "locate":
    let displays = provider.connectedDisplays()
    printDisplays(displays)
    print(placementDescription(runLocate(displays), displays: displays))

case "relocate":
    // Parseo estricto: sin --once no se hace nada.
    var rest = Array(args.dropFirst())
    var target: String?
    var once = false
    while let arg = rest.first {
        rest.removeFirst()
        switch arg {
        case "--once": once = true
        case "--to":
            guard let value = rest.first else { fail("Falta el valor de --to.\n\n\(usage)", code: 64) }
            target = value
            rest.removeFirst()
        default: fail("Argumento desconocido: \(arg)\n\n\(usage)", code: 64)
        }
    }
    guard once else { fail("relocate exige --once (un único intento acotado).\n\n\(usage)", code: 64) }
    guard let targetText = target, let selector = DisplaySelector.parse(targetText) else {
        fail("--to requiere un UUID o un índice válido.\n\n\(usage)", code: 64)
    }

    let displays = provider.connectedDisplays()
    let resolved: DisplayInfo
    switch DisplaySelection.resolve(selector, in: displays) {
    case let .success(display): resolved = display
    case let .failure(error): fail("\(error)", code: 2)
    }
    if resolved.isAmbiguous {
        print("Aviso: este monitor comparte UUID con otro; la elección por índice no es persistible.")
    }
    print("Antes:   \(placementDescription(runLocate(displays), displays: displays))")

    let token = CancellationToken()
    switch CursorDockRelocator().relocate(to: resolved, among: displays, cancel: token) {
    case .success:
        print("Intento completado (cursor restaurado). Esperando que el Dock se asiente…")
        Thread.sleep(forTimeInterval: 1.5)
        let after = provider.connectedDisplays()
        print("Después: \(placementDescription(runLocate(after), displays: after))")
    case let .failure(error):
        fail("Relocación no realizada: \(error.guidance)", code: 3)
    }

default:
    print(usage)
    exit(args.isEmpty ? 0 : 64)
}
