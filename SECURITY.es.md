<!-- source: SECURITY.md@89d097db23d78ca96ddfc7a7b800d7a3f1198715 -->
[English](SECURITY.md) | **Español**

# Política de seguridad

## Versiones soportadas

| Versión | Soportada |
|---|---|
| `ghostty_dart` 0.1.x | ✅ |
| Binarios nativos `native-v1.0.0-r1` (libghostty-vt 1.0.0) | ✅ |

Mientras el paquete esté en 0.x, solo la última versión menor recibe
correcciones. Una corrección en un binario nativo se publica como una nueva
*release* `native-v<versión>-r<n>` junto con una nueva versión del paquete
que fija los nuevos *hashes*.

## Cómo informar de una vulnerabilidad

Envía un informe privado mediante el sistema de informes privados de
vulnerabilidades de GitHub:
**[enviar un informe](https://github.com/AlonsoMCarlos/ghostty_dart/security/advisories/new)**
(el botón «Report a vulnerability» de la pestaña *Security*).

Por favor, no informes de vulnerabilidades en *issues*, *pull requests* ni
debates públicos. No hay ninguna dirección de correo de seguridad.

## Alcance

Dentro del alcance:

- la API de Dart de los paquetes de este repositorio;
- el *build hook*: la descarga, la verificación de *hashes* y las opciones
  de `user_defines`;
- la CI y el proceso de publicación, y los binarios precompilados que
  publica;
- cómo gestionan los *bindings* una entrada de terminal hostil. Un terminal
  analiza salida no confiable, así que los problemas con el acceso al
  portapapeles mediante OSC 52, los hipervínculos OSC 8, la devolución del
  título de la ventana y secuencias similares entran en el alcance cuando intervienen los
  *bindings*.

Fuera del alcance de este proyecto: los fallos de la propia libghostty-vt,
como un cierre inesperado del analizador que se reproduce desde C.
Comunícalos a Ghostty, que también acepta informes privados:
<https://github.com/ghostty-org/ghostty/security/advisories/new>. Si no
sabes dónde está el problema, envía el informe aquí: nos coordinaremos con
upstream y volveremos a publicar los binarios cuando llegue la corrección.

## Qué esperar

El proyecto tiene un único mantenedor, así que las respuestas se dan en la
medida de lo posible. El objetivo es acusar recibo de cada informe en un
plazo de 7 días y mantenerte al tanto hasta resolverlo, pero no hay un
tiempo de respuesta garantizado. Cuando se publique la corrección, se
publicará también el aviso de seguridad, reconociendo tu autoría salvo que
prefieras lo contrario.

## Cómo verificar los binarios precompilados

Tres comprobaciones independientes protegen la biblioteca nativa:

1. **Hashes fijados.** El *build hook* comprueba cada descarga contra el
   sha256 fijado en
   [`lib/src/native/prebuilt.dart`](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/packages/ghostty_dart/lib/src/native/prebuilt.dart)
   y hace fallar la compilación si no coincide. También puedes ejecutar
   `sha256sum -c SHA256SUMS` sobre los archivos de la
   [*release*](https://github.com/AlonsoMCarlos/ghostty_dart/releases/tag/native-v1.0.0-r1).
   `SHA256SUMS` no está firmado; la confianza procede de los *hashes* del
   código fuente publicado del paquete y de las atestaciones.
2. **Procedencia de la compilación.** Cada binario tiene una atestación de
   artefacto de GitHub que lo vincula con la ejecución de CI que lo
   compiló:

   ```sh
   gh attestation verify libghostty-vt-linux-x64.so \
     --repo AlonsoMCarlos/ghostty_dart
   ```

3. **Compilaciones reproducibles.** Todos los binarios salvo los de Apple
   son reproducibles bit a bit: vuelve a compilar uno con
   `mise run native:release-asset <asset>` y compara el *hash*. La
   compilación parte del *tarball* oficial, cuya firma minisign se
   comprueba con la clave de
   [`native/upstream.json`](https://github.com/AlonsoMCarlos/ghostty_dart/blob/main/native/upstream.json).

Si prefieres no descargar nada, `source: path` y `source: system` te
permiten aportar tu propia biblioteca. Consulta el tema
[Build hook options](https://pub.dev/documentation/ghostty_dart/latest/topics/build-hook-options-topic.html)
(en inglés).
