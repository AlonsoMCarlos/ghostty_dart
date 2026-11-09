<!-- source: README.md@b280338cebc1e46a2f5b30b3f313314a8fdb8f7d -->
[English](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart/README.md) | **Español**

# ghostty_dart

[![pub package](https://img.shields.io/pub/v/ghostty_dart.svg)](https://pub.dev/packages/ghostty_dart)
[![pub points](https://img.shields.io/pub/points/ghostty_dart)](https://pub.dev/packages/ghostty_dart/score)
[![CI](https://github.com/AlonsoMCarlos/ghostty_dart/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/AlonsoMCarlos/ghostty_dart/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart/LICENSE)

*Bindings* de Dart para [libghostty-vt](https://lib.ghostty.org/vt/) 1.x, el
motor de emulación de terminal de [Ghostty](https://ghostty.org). Recibe los
bytes que un programa escribe en su pty y devuelve una pantalla emulada por
completo: celdas, estilos, colores, cursor, historial (*scrollback*), modos
y las respuestas que el programa espera.

> [!NOTE]
> **No oficial.** Es un proyecto independiente, sin afiliación, respaldo
> ni patrocinio del proyecto Ghostty ni de Hack Club. «Ghostty» es una
> marca de sus respectivos titulares y aquí solo se usa para describir la
> biblioteca a la que enlaza este paquete.

- **Toda la API en C de libghostty-vt 1.0, en Dart idiomático.** Estado y
  opciones del terminal, todos los *callbacks* (respuestas a la pty, campana,
  título, portapapeles…), un estado de renderizado por lotes, codificación
  de teclado y ratón (incluido el protocolo de teclado de Kitty), selección,
  búsqueda, formateo, instantáneas y gráficos de Kitty. Sin tipos de
  `dart:ffi` en la API pública y sin depender de Flutter.
- **Procesamiento de entrada rápido.** En nuestro *benchmark* consumió la
  salida de la pty entre 3,8 y 7,6 veces más rápido que el más rápido
  entre xterm 4.0.0 y xterm2_core (AOT, bloques de 64 KiB, de extremo a
  extremo), con menos crecimiento de memoria. Las cifras y sus salvedades
  están en [Benchmarks](#benchmarks).
- **Sin necesidad de compilar nada.** El *build hook* descarga un binario
  precompilado para tu plataforma de destino (12 en total), lo verifica
  contra un sha256 fijado en el código fuente del paquete y hace fallar la
  compilación ante cualquier discrepancia. Cada binario tiene una atestación de procedencia de
  compilación.

## Plataformas

| Plataforma | Binario precompilado | Pruebas |
|---|---|---|
| Linux x64, arm64 (glibc 2.28+) | ✅ | Batería de pruebas completa |
| macOS arm64, x64 (macOS 13+) | ✅ | Batería de pruebas completa |
| Windows x64, arm64 | ✅ | Batería de pruebas completa (arm64 sin garantías) |
| Android arm64, arm, x64 (API 24+) | ✅ | Solo comprobaciones de formato (símbolos exportados, dependencias, páginas de 16 KB) |
| iOS arm64, simulador arm64 y x64 (iOS 14+) | ✅ | Solo comprobaciones de formato |
| Web (wasm) | — | Previsto |

La batería de pruebas completa se ejecuta en cada *pull request* en Linux
x64, macOS arm64 y Windows x64, y contra los binarios de cada *release* en
las seis plataformas de escritorio (se suman Linux arm64, macOS x64 y
Windows arm64).

## Inicio rápido

```sh
dart pub add ghostty_dart
```

```dart
import 'dart:convert';

import 'package:ghostty_dart/ghostty_dart.dart';

void main() {
  final terminal = VtTerminal(cols: 80, rows: 24);
  terminal.write(utf8.encode('Hello, \x1b[1;32mworld\x1b[0m!\r\n'));
  print(TerminalFormatter(terminal).formatText()); // Hello, world!
  terminal.dispose(); // also frees the formatter
}
```

Para dibujar una pantalla, actualiza un `RenderState` una vez por fotograma
y recorre sus filas modificadas por tramos de estilo: así haces una llamada
de dibujo por tramo, no por celda:

```dart
final renderState = RenderState();
terminal.onWritePty = replies.add; // queue; send to the pty later
terminal.write(chunk); // a Uint8List read from the pty

renderState.update(terminal);
for (final row in renderState.dirtyRows) {
  for (var x = 0; x < row.length; x = row.styleRunEnd(x)) {
    final style = row.styleAt(x); // draw the run [x, styleRunEnd(x))
  }
}
renderState.markClean(); // frame drawn: clears the dirty flags
renderState.dispose();
```

Los objetos nativos pertenecen a sus envoltorios de Dart: llama a
`dispose()` cuando termines (un *finalizer* actúa como red de seguridad).
Un recorrido más largo, con efectos, renderizado ANSI, codificación de
teclas, selección, copia y búsqueda, está en
[`example/main.dart`](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart/example/main.dart).

**Hoja de ruta:** están previstos, como paquetes aparte, un *widget* de
Flutter (`ghostty_dart_flutter`) y un adaptador con la API de
`package:xterm` 4.0.0 (`ghostty_dart_xterm`), así como un *backend* web
(wasm). Ninguno existe todavía.

## Benchmarks

Rendimiento del procesamiento de entrada (análisis VT y actualización de la
pantalla y del historial) sobre los mismos flujos de bytes deterministas,
medido el 2026-11-09: AMD Ryzen 5 3600, Linux, Dart 3.13.7, libghostty-vt
1.0.0 ReleaseFast, AOT, bloques de 64 KiB y un terminal de 200×50 con
10 000 líneas de historial. Los motores xterm incluyen la decodificación
UTF-8, como hacen las aplicaciones que leen de una pty.

| Carga | ghostty_dart | xterm 4.0.0 | xterm2_core 1.0.0 | Aceleración frente al más rápido del resto |
|---|---:|---:|---:|---:|
| `ascii` | 99,5 MB/s | 11,6 MB/s | 24,4 MB/s | 4,1× |
| `sgr` | 88,9 MB/s | 15,1 MB/s | 23,4 MB/s | 3,8× |
| `unicode` | 131,8 MB/s | 25,1 MB/s | 8,7 MB/s | 5,3× |
| `tui` | 171,4 MB/s | 14,4 MB/s | 22,7 MB/s | 7,6× |
| `wrapped` | 318,5 MB/s | 14,2 MB/s | 57,5 MB/s | 5,5× |

La memoria residente creció entre +0,5 y +17,6 MiB con ghostty_dart, frente
a entre +1,5 y +81,2 MiB con los motores xterm, en las mismas cargas.

Salvedades, en resumen:

- Solo se mide el procesamiento de la entrada, no el pintado, la
  maquetación ni los *widgets*, así que estas cifras no predicen los
  fotogramas por segundo de una aplicación Flutter.
- El historial de 10 000 líneas, usado para que la comparación sea justa, es
  la configuración lenta de libghostty-vt 1.0.0; con su límite por bytes
  predeterminado es bastante más rápido.
- En la carga `unicode` las pantallas difieren en la disposición de las
  celdas: libghostty-vt agrupa grafemas, mientras que los motores xterm dan
  a cada punto de código su propio ancho.
- Es una única máquina virtual compartida en la nube, así que cabe esperar
  un pequeño porcentaje de ruido, y las diferencias de RSS son aproximadas.
  Vuelve a ejecutarlo en tu hardware antes de citar una cifra.

La metodología, las tablas JIT y de 4 KiB, las comprobaciones de corrección
y todas las salvedades están en
[`benchmarks/README.md`](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/benchmarks/README.md),
junto con la orden que las reproduce.

## Comparación

Datos a 9 de noviembre de 2026. Cada uno de estos proyectos optó por
compromisos distintos, y
`xterm`, en particular, es hoy la opción madura y más extendida.

| Paquete | Motor | *Widget* de Flutter | Web | API de `xterm` 4.0.0 |
|---|---|---|---|---|
| `ghostty_dart` 0.1.0 | libghostty-vt 1.0.0 (ABI en C estable), FFI | No (previsto, en otro paquete) | No (previsto) | No (adaptador previsto) |
| [`xterm`](https://pub.dev/packages/xterm) 4.0.0 | Dart puro | Sí | Sí | Es la propia API |
| [`xterm2`](https://pub.dev/packages/xterm2) 5.4.0 | Dart puro (`xterm2_core`) | Sí | Sí | La misma API (es un *fork*) |
| [`libghostty`](https://pub.dev/packages/libghostty) 0.0.13 + [`flterm`](https://pub.dev/packages/flterm) 0.0.6 | Un *commit* de libghostty-vt anterior a 1.0, FFI y wasm | Sí (`flterm`) | Sí | No |

Lo que `ghostty_dart` **todavía no** hace: no tiene *widget*, así que la
pantalla la dibujas tú; no funciona en la web; y no puede sustituir a
`package:xterm` en una aplicación existente. Si hoy necesitas algo de eso,
los paquetes de la tabla ya lo ofrecen.

## Cadena de suministro

El *build hook* se ejecuta en tu máquina, así que se le exige un estándar
estricto:

- **Fijado y verificado.** La fuente predeterminada, `prebuilt`, descarga el
  binario de tu plataforma desde la *release* de GitHub
  [`native-v1.0.0-r1`](https://github.com/AlonsoMCarlos/ghostty_dart/releases/tag/native-v1.0.0-r1)
  (con su `SHA256SUMS`) y lo comprueba contra el sha256 fijado en el código
  del paquete. Si no coincide, la compilación falla. El *hook* nunca
  ejecuta código descargado ni descarga nada que no esté fijado.
- **Compilado en CI a partir de código firmado.** La CI de este repositorio
  compila los binarios a partir del *tarball* oficial de libghostty-vt,
  tras comprobar su firma minisign y un sha256 fijado.
- **Con atestación y reproducible.** Cada binario lleva una atestación de
  procedencia de compilación, y todos salvo los de Apple son reproducibles
  bit a bit.

Para comprobar los binarios tú mismo (sumas de comprobación, atestaciones y
recompilación), sigue
[Cómo verificar los binarios precompilados](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/SECURITY.es.md#cómo-verificar-los-binarios-precompilados)
en la política de seguridad. Además, el repositorio versiona sus
*lockfiles* y no adopta ninguna versión de una dependencia publicada hace
menos de 3 días.

## Opciones del build hook

Se definen en `hooks: user_defines: ghostty_dart:` del `pubspec.yaml` raíz:

```yaml
hooks:
  user_defines:
    ghostty_dart:
      source: path    # prebuilt (default), path or system
      path: path/to/libghostty-vt.so.1.0.0
```

- `source: prebuilt` (predeterminada) descarga el binario fijado.
  `url_pattern` lo dirige a un espejo https; el sha256 fijado se sigue
  verificando.
- `source: path` usa un archivo de biblioteca, o un directorio que lo
  contenga, para compilar sin red o usar una biblioteca compilada por ti.
- `source: system` carga una libghostty-vt 1.x instalada en el sistema.

La referencia completa (variables de sustitución, tiempos de espera,
*proxies* y versiones mínimas de cada sistema operativo) está en el tema [Build hook options](https://pub.dev/documentation/ghostty_dart/latest/topics/build-hook-options-topic.html),
en inglés.

## Documentación

- [Referencia de la API](https://pub.dev/documentation/ghostty_dart/latest/) (en inglés)
- [Build hook options](https://pub.dev/documentation/ghostty_dart/latest/topics/build-hook-options-topic.html) (en inglés)
- [Registro de cambios](https://pub.dev/packages/ghostty_dart/changelog) (en inglés)
- [Cómo contribuir](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/CONTRIBUTING.es.md)
  y [política de seguridad](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/SECURITY.es.md)
- [Incidencias](https://github.com/AlonsoMCarlos/ghostty_dart/issues)

## Licencia

Este paquete se distribuye bajo la licencia MIT (consulta
[LICENSE](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart/LICENSE)).
libghostty-vt, que el *build hook* proporciona como biblioteca nativa,
también tiene licencia MIT (Copyright (c) 2024 Mitchell Hashimoto, Ghostty
contributors); las aplicaciones que la distribuyan deben incluir su aviso.
