<!-- source: README.md@6bf3fbfbda495829f2d9ca54b0f4104d3268a80a -->
[English](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart_xterm/README.md) | **Español**

# ghostty_dart_xterm

[![CI](https://github.com/AlonsoMCarlos/ghostty_dart/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/AlonsoMCarlos/ghostty_dart/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart_xterm/LICENSE)

Un adaptador que ofrece la API pública de
[`xterm`](https://pub.dev/packages/xterm) 4.0.0 sobre
[`ghostty_dart`](https://pub.dev/packages/ghostty_dart) y
[`ghostty_dart_flutter`](https://pub.dev/packages/ghostty_dart_flutter),
que ejecutan [libghostty-vt](https://lib.ghostty.org/vt/) 1.x, el motor de
emulación de terminal de [Ghostty](https://ghostty.org). El objetivo es
que una aplicación deje `xterm` cambiando solo su `import`.

> [!NOTE]
> **No oficial.** Es un proyecto independiente. No está afiliado al
> proyecto Ghostty ni a Hack Club, ni a los autores de `xterm`, ni cuenta
> con su respaldo o patrocinio. «Ghostty» es una marca de sus respectivos
> propietarios y aquí solo se usa para describir sobre qué se construye
> este paquete.

> [!WARNING]
> **En desarrollo, sin publicar.** Por ahora solo existen los tipos de
> valor de xterm (`CellOffset`, `BufferRange`, `CursorStyle`,
> `TerminalState`, …); `Terminal`, `TerminalView` y
> `TerminalController` se están escribiendo. El diseño está en el
> [ADR 0013](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/docs/internal/adr/0013-xterm-adapter-design.md).
> No lo llamaremos sustituto directo (*drop-in*) hasta que un
> `COMPATIBILITY.md` generado y los propios tests de xterm, portados y en
> verde, lo demuestren.

- **La API de xterm.** Los mismos nombres de clases, miembros y parámetros
  que `xterm` 4.0.0, con cada diferencia listada miembro a miembro.
- **El motor de Ghostty.** El análisis de secuencias, la pantalla, el
  historial y la codificación de teclas vienen de libghostty-vt en lugar
  de un emulador en Dart.
- **El renderizador de `ghostty_dart_flutter`**, que solo vuelve a dibujar
  las filas que cambiaron.

## Plataformas

| Plataforma | Estado |
|---|---|
| Linux, macOS, Windows | En desarrollo |
| Android, iOS | En desarrollo (aún sin probar en un dispositivo) |
| Web | Prevista: necesita un *backend* wasm en `ghostty_dart` |

## Inicio rápido

Aún no se puede usar. Cuando existan `Terminal` y `TerminalView`:

```dart
// import 'package:xterm/xterm.dart';
import 'package:ghostty_dart_xterm/xterm.dart';
```

## Licencia

MIT (véase `LICENSE`). Algunas partes se portaron de `xterm` 4.0.0,
también MIT; véase
[`LICENSE.xterm`](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart_xterm/LICENSE.xterm).
