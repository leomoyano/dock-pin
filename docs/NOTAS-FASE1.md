# Notas Fase 1 — prototipo del mecanismo

Alcance: SwiftPM (macOS 14, Swift 6.4), sin UI ni login item. Enforcement por **corrección posterior** (se detecta y se corrige; no se previene la migración).

## Qué se implementó

| Pieza | Archivo | Estado |
| --- | --- | --- |
| `DisplayIdentity` / enumeración / resolución de selector | `DisplayIdentity.swift` | Probado con tests puros; enumeración real corrida con `displays` |
| `DockLocator` (ventanas owner `Dock`, layer dock, punto medio) | `DockLocator.swift` | Tests puros; corrido `locate` (1 sola corrida, ver abajo) |
| `EnforcementPolicy` (máquina de estados pura, reloj inyectado) | `EnforcementPolicy.swift` | 20 tests, una por regla |
| `DockRelocator` (warp + dwell en borde inferior, restaura cursor) | `DockRelocator.swift` | Solo tests con fakes. **Nunca ejecutado de verdad** |
| CLI `dockpin-probe displays\|locate\|relocate --to <uuid\|índice> --once` | `Sources/dockpin-probe` | `relocate` compilado, NO ejecutado |

Decisiones:
- **Identidad**: UUID de `CGDisplayCreateUUIDFromDisplayID`. Si dos monitores conectados comparten UUID quedan marcados `isAmbiguous`: por UUID se rechaza (`ambiguousIdentity`), por índice se permite con aviso, el locator devuelve `unknown(.ambiguousDisplay)` y el relocator se niega. No se persiste una elección ambigua.
- **Dock no localizable = desconocido**, nunca "monitor equivocado"; la política no mueve nada ante `unknown`.
- **Política** (defaults en `EnforcementConfig`): debounce 2 s tras display/wake, cooldown 5 s entre intentos (global, sobrevive al reinicio de racha), máx. 3 intentos por racha, timeout de intento 4 s, 1 s de quietud del usuario antes de empezar, poll 10 s. Actividad del usuario cancela el intento y cuenta contra el presupuesto. Monitor desconectado: sin movimientos ni reintentos hasta un evento de display. Agotados los intentos o error no reintentable (p. ej. sin Accesibilidad): `gaveUp` hasta un disparador externo.
- **Relocator**: exige `AXIsProcessTrusted`, no empieza con botón presionado, se niega si el borde inferior está cubierto por otro monitor, sostiene el cursor 1.5 s contra el borde con `mouseMoved` mínimos, restaura la posición original, siempre `CGAssociateMouseAndMouseCursorPosition(1)`, jamás oculta el cursor. Si el usuario mueve el mouse, abandona **sin** restaurar.

## Validado en esta máquina

- `swift build` y `swift test` (45 tests) pasan.
- `dockpin-probe displays`: 2 monitores, UUIDs distintos, frames coherentes con la disposición (el secundario en x=-1920).
- `dockpin-probe locate`: detectó el Dock en el monitor `[1]`. Es una sola observación con Dock visible; no valida autohide ni Spaces.

## Sin validar en runtime (checklist del brief)

- [ ] Mecanismo de enforcement durante uso normal (¿alcanza la corrección posterior? ¿latencia perceptible?).
- [ ] Que warp + dwell realmente haga migrar el Dock; duración mínima del dwell; si los `nudge` ayudan o estorban; supresión de eventos locales tras el warp.
- [ ] Coordenadas objetivo con monitores en vertical, bordes parcialmente expuestos y distintas escalas.
- [ ] Dock visible vs autohide; decidir si Dock inferior es prerrequisito del MVP (hoy el relocator asume inferior).
- [ ] Locator: layer `dockWindowLevel` y ventanas extra del Dock; comportamiento con Spaces/fullscreen; permisos necesarios en macOS 27.
- [ ] Que el cursor/input del usuario no se perturben (incluye hot corners al restaurar).
- [ ] Cancelación, cooldown y límites con eventos reales (la política solo se probó con reloj manual; el driver que une política + locator + relocator + notificaciones de display/wake **no existe todavía**).
- [ ] Monitores idénticos: ¿el UUID realmente colisiona en hardware real?
- [ ] Login, wake, desconexión/reconexión, cambio de geometría.
- [ ] No correr dos controladores del Dock a la vez (DockLock, etc.).

## Plan de prueba controlada con Leo

Antes:
1. **Cerrar DockLock Lite** (y cualquier otro controlador del Dock); verificar que no queden procesos.
2. Dar **Accesibilidad** a la terminal que va a ejecutar el probe (Ajustes del Sistema > Privacidad y seguridad > Accesibilidad). Sin eso, `relocate` falla con mensaje accionable sin tocar el cursor.
3. Dock abajo, sin autohide en la primera pasada; disposición de monitores conocida (anotar la salida de `displays`).
4. Cerrar menús / Centro de Control; Leo con las manos fuera del mouse durante el intento.

Qué va a pasar con el cursor: al ejecutar `dockpin-probe relocate --to <uuid|índice> --once`, el cursor salta al borde inferior del monitor objetivo, queda ahí ~1.5 s y vuelve a su posición original. El Dock debería migrar en ese lapso. Si Leo mueve el mouse o presiona un botón, el intento se aborta y el cursor queda donde Leo lo puso. Luego el probe espera 1.5 s e imprime dónde quedó el Dock.

Orden sugerido: `displays` → `locate` (antes) → `relocate ... --once` (hacia el monitor donde el Dock NO está) → `locate` (después) → repetir con autohide y con el borde cubierto para ver los rechazos.
