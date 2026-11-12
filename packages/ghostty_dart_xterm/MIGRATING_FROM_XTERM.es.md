<!-- source: MIGRATING_FROM_XTERM.md@251986903ff6b9c8101841b41ab81991d63619f5 -->
[English](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart_xterm/MIGRATING_FROM_XTERM.md) | **Español**

# Migrar desde xterm 4.0.0

`ghostty_dart_xterm` conserva la API pública de
[`xterm`](https://pub.dev/packages/xterm) 4.0.0 y sustituye lo que hay
debajo: libghostty-vt analiza la salida y guarda la pantalla, y
`ghostty_dart_flutter` la dibuja. Esta guía es para autores de
aplicaciones. La lista completa y generada de miembros es
[`COMPATIBILITY.md`](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart_xterm/COMPATIBILITY.md)
(en inglés); esta página explica las diferencias que importan en la
práctica.

## 1. Cambia la dependencia y los *imports*

```yaml
dependencies:
  # xterm: ^4.0.0
  ghostty_dart_xterm: ^0.1.0
```

Cada biblioteca de xterm tiene una equivalente con el mismo nombre:

| `xterm` 4.0.0 | `ghostty_dart_xterm` |
|---|---|
| `package:xterm/xterm.dart` | `package:ghostty_dart_xterm/xterm.dart` |
| `package:xterm/core.dart` | `package:ghostty_dart_xterm/core.dart` (sin *widgets*, como en xterm) |
| `package:xterm/ui.dart` | `package:ghostty_dart_xterm/ui.dart` |
| `package:xterm/suggestion.dart` | `package:ghostty_dart_xterm/suggestion.dart` |
| `package:xterm/zmodem.dart` | Todavía no (requiere el paquete `zmodem`) |
| `package:xterm/utils.dart` | Existe, pero está vacía: el depurador se basa en el *parser* en Dart de xterm |

`xterm.dart` exporta `core.dart` y `ui.dart`; a diferencia del de xterm,
todavía no exporta `zmodem.dart`.

## 2. Libera el terminal

Un `Terminal` ocupa memoria nativa (el terminal de libghostty-vt) que el
recolector de basura de Dart no ve. Llama a `terminal.dispose()` cuando
termines con él, normalmente en tu `State.dispose`. `TerminalView` nunca lo
libera, igual que en xterm. Después, cualquier miembro que llegue al motor
lanza `StateError`. Un terminal que nunca liberes lo acaba liberando un
*finalizer*, pero no enseguida.

```dart
@override
void dispose() {
  terminal.dispose(); // no existe en xterm
  super.dispose();
}
```

## 3. Código típico, sin cambios

Los propios ejemplos de xterm funcionan cambiando solo el *import*; los
tests del paquete se aseguran de que sigan compilando
([`test/migration/`](https://github.com/AlonsoMCarlos/ghostty_dart/tree/main/packages/ghostty_dart_xterm/test/migration)).

### Una shell local con `flutter_pty`

```dart
import 'dart:convert';

import 'package:flutter_pty/flutter_pty.dart';
import 'package:ghostty_dart_xterm/xterm.dart';

final terminal = Terminal(maxLines: 10000);

void startShell(String shell) {
  final pty = Pty.start(
    shell,
    columns: terminal.viewWidth,
    rows: terminal.viewHeight,
  );
  pty.output
      .cast<List<int>>()
      .transform(const Utf8Decoder())
      .listen(terminal.write);
  terminal.onOutput = (data) => pty.write(const Utf8Encoder().convert(data));
  terminal.onResize = (w, h, pw, ph) => pty.resize(h, w);
}
```

### Una shell local con `flutter_pty2`, sin pasar por cadenas

Los añadidos `writeBytes` y `onOutputBytes` reciben y entregan bytes.
Úsalos en lugar de `write` y `onOutput`, no a la vez: las dos *callbacks*
de salida se llaman con cada bloque.

```dart
import 'package:flutter_pty2/flutter_pty2.dart';
import 'package:ghostty_dart_xterm/xterm.dart';

Future<void> startShell(Terminal terminal, String shell) async {
  final session = await Pty.spawn(
    PtySpawnOptions(
      executable: shell,
      size: PtySize(columns: terminal.viewWidth, rows: terminal.viewHeight),
    ),
  );
  session.output.listen(terminal.writeBytes);
  terminal.onOutputBytes = (bytes) => session.input.write(bytes);
  terminal.onResize = (w, h, pw, ph) =>
      session.resize(PtySize(columns: w, rows: h));
}
```

### Una sesión SSH con `dartssh2`

```dart
final session = await client.shell(
  pty: SSHPtyConfig(width: terminal.viewWidth, height: terminal.viewHeight),
);
terminal.buffer.clear();
terminal.buffer.setCursor(0, 0);
terminal.onTitleChange = (title) => setState(() => this.title = title);
terminal.onResize = (w, h, pw, ph) => session.resizeTerminal(w, h, pw, ph);
terminal.onOutput = (data) => session.write(utf8.encode(data));
session.stdout
    .cast<List<int>>()
    .transform(const Utf8Decoder())
    .listen(terminal.write);
```

Un teclado virtual escrito como `class VirtualKeyboard extends
TerminalInputHandler with ChangeNotifier` y pasado como
`Terminal(inputHandler: keyboard)` funciona igual que en xterm.

## 4. Qué se comporta de otra forma

### Teclas

- **Escritas en `TerminalView`, con el `inputHandler` por defecto:** las
  teclas las codifica libghostty-vt, como en la aplicación Ghostty. La
  mayoría de los bytes coinciden con el *keytab* de xterm. Difieren cuando
  libghostty-vt sigue un protocolo que el programa ha pedido (el protocolo
  de teclado de Kitty, `modifyOtherKeys`) o una convención habitual de los
  terminales, por ejemplo Ctrl+Retroceso. AltGr y la entrada por IME
  funcionan como en cualquier terminal de escritorio.
- **Con tu propio `inputHandler`** (un teclado virtual, teclas
  reasignadas): recibe todas las teclas, como en xterm, y su salida se
  envía sin cambios.
- **`terminal.keyInput(...)`** siempre ejecuta la cadena de manejadores de
  xterm, así que sus bytes coinciden con los de xterm, con una corrección:
  las teclas de cursor en modo aplicación siguen DECCKM (`cursorKeysMode`);
  xterm 4.0.0 lee ahí el modo del teclado numérico.

### Atajos

`TerminalView` conserva los `defaultTerminalShortcuts` de xterm:
Ctrl+Mayús+C copia, Ctrl+V pega y Ctrl+A selecciona todo (Cmd en las
plataformas de Apple). Cambian dos detalles: seleccionar todo incluye el
historial, no solo la pantalla, y pegar nunca pide confirmación (como en
xterm; la vista propia de `ghostty_dart_flutter` retiene los pegados
inseguros). Si quieres que Ctrl+V y Ctrl+A lleguen a la shell, pasa tus
propios `shortcuts:`.

### Ratón

- Los informes de ratón al programa vienen del codificador de
  libghostty-vt: todos los formatos y la **fila correcta**. xterm 4.0.0
  informa una fila de menos en sus formatos normal y UTF-8; los programas
  que lo compensaban quedarán desplazados una fila en sentido contrario.
- `TerminalController.setPointerInputs` con `drag` o `move` informa de
  verdad de los arrastres y del movimiento (xterm 4.0.0 nunca lo hace).
  Suspender la entrada del puntero (`setSuspendPointerInput`) también
  detiene los informes de la rueda.
- `onTapUp` se llama para un clic que no seleccionó nada y que no se
  informó al programa.

### La pantalla y el historial

- **La pantalla inactiva se lee en blanco.** libghostty-vt solo expone la
  pantalla activa, así que mientras un programa a pantalla completa (vim,
  htop) usa la pantalla alternativa, `terminal.mainBuffer` se lee como
  líneas en blanco con el cursor en 0, 0, y al revés. Lee el *buffer* que
  necesites mientras esté activo.
- **`maxLines` es aproximado.** libghostty-vt descarta el historial en
  páginas enteras, así que se conservan más líneas que `maxLines` (unas
  300 a 80 columnas con `maxLines: 30`). No hay límite en bytes.
- **Las líneas son instantáneas.** `buffer.lines[i]` se construye desde el
  motor la primera vez que se accede y se guarda hasta que el terminal
  cambia; modificar un `BufferLine` leído solo cambia esa copia. Sirve
  para copiar y buscar, pero es demasiado lento para recorrer todo el
  historial en cada fotograma.
- **Reflow.** Un cambio de tamaño de `TerminalView` siempre reajusta el
  texto; `reflowEnabled: false` solo se aplica a `terminal.resize(...)`.
  Sin *reflow*, las celdas que quedan fuera de un ancho menor se descartan
  en lugar de guardarse para un cambio posterior a un ancho mayor.
- **Las anclas** (`buffer.createAnchor`, las selecciones) las sigue
  libghostty-vt: acompañan al desplazamiento y al *reflow*, pero no a las
  líneas movidas al insertar o borrar líneas (IL, DL) ni por una región de
  desplazamiento. Cada una ocupa algo de memoria nativa hasta que se
  libera.
- **Los márgenes de desplazamiento** (DECSTBM) no están expuestos:
  `Buffer.marginTop` y `marginBottom` no reflejan lo que fijó el programa.

### *Callbacks*

- Los eventos que provoca la salida (`onBell`, `onTitleChange`, las
  respuestas en `onOutput`, `onPrivateOSC`, `onResize`) se entregan en
  orden **después** de analizar el bloque pasado a `write`, no a mitad.
  Una *callback* puede volver a llamar a `write`.
- `onIconChange` solo se dispara desde `setIconName`: libghostty-vt 1.0.0
  no informa del nombre del icono de OSC 0 ni de OSC 1.
- `onPrivateOSC` solo ve las secuencias OSC que libghostty-vt no implementa
  por sí mismo. Ghostty implementa muchas que xterm reenviaba (por
  ejemplo, OSC 66, el ajuste de tamaño de texto de Kitty), así que esas
  nunca llegan.
- `onOutput` recibe los bytes de libghostty-vt (teclas e informes de ratón
  escritos en la vista, respuestas a consultas) decodificados como UTF-8,
  o como Latin-1 en un bloque que no sea UTF-8 válido. `onOutputBytes`
  tiene los bytes exactos.
- `onResize` recibe, cuando la vista cambia el tamaño del terminal, el
  tamaño de celda en píxeles lógicos, a partir de la densidad de píxeles
  de la vista, como lo calcula xterm; solo se llama cuando el tamaño
  cambia.

### Interioridades del emulador

- `Terminal` no es un `EscapeHandler`, y `EscapeParser` no existe: el
  análisis es nativo. Los métodos de manejador de `Terminal` (`setCursor`,
  `eraseDisplay`, `useAltBuffer`, …) siguen funcionando: cada uno escribe
  la secuencia de escape equivalente. Lanzan `StateError` si la salida se
  detuvo a mitad de una secuencia. Los métodos sin secuencia
  (`unknownCSI`, …) no hacen nada.
- `Buffer.clear()` y `setCursor()` funcionan mediante secuencias sobre el
  *buffer* activo; `Buffer.resize` no está soportado (cambia el tamaño del
  terminal).
- `TerminalViewState.renderTerminal` no existe: el objeto de renderizado
  es el de `ghostty_dart_flutter`. `TerminalView.scrollController` se
  acepta y se ignora, porque el desplazamiento lo gestiona libghostty-vt.

### Una vista, plataformas nativas

- Muestra cada `Terminal` en **un solo `TerminalView` a la vez**.
- **Todavía sin web.** El paquete funciona en Linux, macOS, Windows,
  Android e iOS. La web requiere un *backend* wasm en `ghostty_dart`;
  mientras tanto, una aplicación que se publique para la web tiene que
  seguir usando `xterm` allí.
- Las celdas se miden a partir de la fuente y se ajustan a píxeles del
  dispositivo, así que una celda puede ser algo mayor o menor que en xterm
  con el mismo `TerminalStyle`, y en una pantalla puede caber una columna
  más o una menos.

## 5. Si algo no funciona

Busca el miembro en
[`COMPATIBILITY.md`](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart_xterm/COMPATIBILITY.md).
Si figura como ✅ y se comporta distinto que en xterm 4.0.0, es un error:
por favor, [abre un *issue*](https://github.com/AlonsoMCarlos/ghostty_dart/issues)
con el código más pequeño que lo muestre.
