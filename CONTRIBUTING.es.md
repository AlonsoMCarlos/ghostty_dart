<!-- source: CONTRIBUTING.md@541619b33a31261c392acac324ed10a95c02396c -->
[English](CONTRIBUTING.md) | **Español**

# Cómo contribuir

Gracias por tu interés en ghostty_dart. Es un proyecto independiente y no
oficial; no forma parte de Ghostty. Son bienvenidos los informes de
errores, las correcciones, las pruebas y la documentación. Si el cambio es
grande, abre primero un *issue* para acordar el enfoque antes de dedicarle
tiempo.

Esta página es la versión breve. [`AGENTS.md`](AGENTS.md) es la guía
completa (tanto para personas como para agentes de IA), y las decisiones
del proyecto están registradas como ADR en
[`docs/internal/adr/`](docs/internal/adr). Ambos están en inglés.

## Configuración

[mise](https://mise.jdx.dev) gestiona todas las herramientas, en las
versiones exactas de `mise.toml` (Flutter y su SDK de Dart, Zig, minisign,
jq y otras):

```sh
mise install            # the pinned tools
mise run deps           # flutter pub get --enforce-lockfile
mise run native:host    # libghostty-vt for this machine (every test, demo and bench task needs it)
mise run check          # everything CI runs
```

`mise tasks` muestra todas las tareas. No instales herramientas del
proyecto de forma global ni a mano: añádelas a `mise.toml`. Solo unas pocas
cosas vienen del sistema: `libclang-dev`, necesario únicamente para
regenerar los *bindings* (`mise run ffigen`), y el SDK de Android o Xcode,
necesarios únicamente para compilar para móviles.

## Código

- El código, los comentarios, el dartdoc y los mensajes de *commit* se
  escriben en inglés.
- Ejecuta `mise run format`; `mise run analyze` no debe dar ningún aviso.
- Si cambias el `pubspec.yaml`, un README o el dartdoc, ejecuta también
  `mise run pana` y `mise run publish:dry-run`.
- Todo cambio de comportamiento va acompañado de pruebas.
- Nunca edites a mano el archivo generado `lib/src/ffi/bindings.g.dart`;
  regenéralo.
- Los cambios en `ghostty_dart` siguen las convenciones del ADR 0006
  ([`docs/internal/architecture/ghostty_dart-conventions.md`](docs/internal/architecture/ghostty_dart-conventions.md)).
- Si un cambio contradice un ADR, propón un ADR nuevo que lo sustituya.

## Commits y pull requests

- Usa [Conventional Commits](https://www.conventionalcommits.org/es/v1.0.0/),
  por ejemplo `fix(ghostty_dart): …` o `docs: …`. Las *releases* y los
  registros de cambios se generan a partir de ellos.
- **El título de la *pull request* también debe seguir Conventional
  Commits**: al fusionar con *squash*, se usa como mensaje del *commit*.
- Firma cada *commit* con `git commit -s`. La línea `Signed-off-by`
  certifica el [Developer Certificate of Origin](https://developercertificate.org)
  y debe coincidir con el autor del *commit*.
- Completa la lista de comprobación de la plantilla de *pull request*.

## Cadena de suministro

El código que se ejecuta al compilar (*build hooks*, scripts) corre con tus
permisos, y nuestro *build hook* se ejecuta en las máquinas de los
usuarios, así que estas reglas son estrictas:

- `pubspec.lock` está versionado. Nunca ejecutes `dart pub upgrade` a
  ciegas y revisa cada cambio del *lockfile*.
- Ninguna versión de una dependencia publicada hace menos de 3 días
  (`mise run cooldown` lo comprueba en el *lockfile*).
- Ninguna dependencia nueva en `ghostty_dart` sin justificarla en la *pull
  request*.
- Las GitHub Actions se fijan por SHA de *commit*.
- Lee el código de una biblioteca en `~/.pub-cache` antes de depender de su
  API, en lugar de compilar proyectos de prueba con código sin fijar.

## Documentación en dos idiomas

La documentación para usuarios es bilingüe: `X.md` está en inglés y es la
fuente de verdad, y `X.es.md` es su traducción al español. Si cambias un
archivo en inglés, actualiza el español en la misma *pull request*, o pide
ayuda con la traducción en ella.

Cada archivo en español empieza con una cabecera que indica qué texto en
inglés traduce:

```markdown
<!-- source: X.md@<blob sha> -->
[English](X.md) | **Español**
```

El sha es el resultado de `git hash-object X.md` sobre la versión final del
archivo en inglés. `mise run docs:translations` (que forma parte de
`mise run check`) avisa de las traducciones desactualizadas (una
advertencia) y de las cabeceras ausentes o mal formadas (un error).

## Contribuciones asistidas por IA

Las herramientas de IA son bienvenidas; este mismo repositorio se
desarrolla con ellas. Se aplican dos reglas:

- **Decláralo.** Indica en la *pull request* qué herramienta usaste y para
  qué.
- **Hazte responsable.** Debes entender, y poder explicar, cada línea que
  envíes. No publiques en *issues* ni en revisiones texto generado por IA
  sin revisarlo.

## Conducta y seguridad

Todas las personas que participan siguen el
[código de conducta](CODE_OF_CONDUCT.es.md). No informes de
vulnerabilidades en *issues*: sigue la
[política de seguridad](SECURITY.es.md).
