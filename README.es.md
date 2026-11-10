<!-- source: README.md@0432701acb496f0bd6774ec1e5d6e77656c8c9ce -->
[English](README.md) | **Español**

# ghostty_dart

Paquetes de Dart y Flutter basados en
[libghostty-vt](https://lib.ghostty.org/vt/) 1.x, el motor de emulación de
terminal de [Ghostty](https://ghostty.org), con su ABI en C estable. El
objetivo es una base de terminal rápida y fiable para Dart y Flutter, en
todas las plataformas que podamos soportar.

> [!NOTE]
> **No oficial.** Es un proyecto independiente, sin afiliación, respaldo
> ni patrocinio del proyecto Ghostty ni de Hack Club. «Ghostty» es una
> marca de sus respectivos titulares y aquí solo se usa para describir la
> biblioteca a la que enlazan estos paquetes.

## Paquetes

| Paquete | Qué es | Estado |
|---|---|---|
| [`ghostty_dart`](packages/ghostty_dart/README.es.md) | *Bindings* en Dart puro: toda la API en C de libghostty-vt 1.0, con binarios nativos precompilados, fijados y con atestación | [![pub package](https://img.shields.io/pub/v/ghostty_dart.svg)](https://pub.dev/packages/ghostty_dart) |
| [`ghostty_dart_flutter`](packages/ghostty_dart_flutter/README.es.md) | Un *widget* de terminal para Flutter: renderizado, teclado, ratón, IME, selección y desplazamiento | En este repositorio, aún sin publicar |
| `ghostty_dart_xterm` | Un adaptador con la API pública de [`xterm`](https://pub.dev/packages/xterm) 4.0.0 | Previsto |

También está previsto el soporte web (un *backend* wasm). Mientras no
exista, los paquetes solo funcionan en plataformas nativas; consulta la
[tabla de plataformas](packages/ghostty_dart/README.es.md#plataformas).

## Repositorio

- [`packages/`](packages): los paquetes anteriores.
- [`apps/demo/`](apps/demo): una aplicación de Flutter que ejecuta tu shell
  en la vista de terminal de `ghostty_dart_flutter` (Linux, macOS, Windows).
- [`benchmarks/`](benchmarks): *benchmarks* reproducibles frente a xterm
  4.0.0 y xterm2: rendimiento del *parser* y tiempos de fotograma de los
  *widgets*.
- [`native/`](native) y [`tool/native/`](tool/native): la versión fijada de
  upstream y los scripts que compilan los binarios nativos en CI.
- [`docs/internal/`](docs/internal): registros de decisiones de arquitectura
  (ADR) y notas de investigación, en inglés.

## Contribuciones y seguridad

- [Cómo contribuir](CONTRIBUTING.es.md): configuración, reglas de los
  *commits* y de la cadena de suministro. [`AGENTS.md`](AGENTS.md) contiene
  la guía completa del proyecto, en inglés.
- [Código de conducta](CODE_OF_CONDUCT.es.md).
- [Política de seguridad](SECURITY.es.md): informa de las vulnerabilidades
  en privado, nunca en un *issue* público.

## Licencia

MIT; consulta [LICENSE](LICENSE). libghostty-vt también tiene licencia MIT
(Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors).
