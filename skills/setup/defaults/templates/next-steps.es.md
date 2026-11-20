Plantilla de "Qué hago ahora" (chief-of-staff), versión del equipo en español. Viene con el kit; si la editás en tu copia instalada, una actualización respeta tu versión y te propone combinarla con la nueva.

Cada texto empieza con una línea que tiene solo `<!-- @nombre -->` y sigue hasta el próximo. `{{dato}}` se reemplaza por un dato; un dato que no existe queda vacío. Este párrafo no se usa.

Para cambiar un texto solo para vos, en vez de editar este archivo conviene escribir en tu plantilla propia (`paths.templates.nextSteps` en la configuración) solo los textos que cambiás, cada uno con su misma línea `@nombre`. Los tuyos ganan, y tu plantilla nunca hay que combinarla al actualizar.

Los motivos (`reason.<regla>`) van uno por regla de `chief.rules`; una regla que agregaste vos y no tiene motivo acá usa `reason.other`. Las acciones (`action.<acción>` y `label.<acción>`) van una por acción.

<!-- @format.culture -->
es-AR
<!-- @format.date -->
dd/MM
<!-- @format.dateTime -->
dd/MM HH:mm

<!-- @plan -->
## Qué hago ahora

{{partial}}

{{items}}

{{more}}

{{skipped}}
<!-- @plan.item -->
{{n}}. [{{key}}]({{link}}) · {{summary}} · {{status}}
   - Por qué: {{reason}}
   - Propongo: {{action}}.
<!-- @plan.last -->
   - Antes: {{label}}, {{outcome}} el {{when}}{{note}}.
<!-- @plan.note -->
 ({{note}})
<!-- @plan.none -->
Nada para proponer ahora: ningún ticket de tus vistas pide algo de vos.
<!-- @plan.more -->
Hay {{count}} más; te los propongo cuando avances con estos.
<!-- @plan.skipped -->
No te propongo de nuevo, por ahora: {{items}}.
<!-- @plan.partial -->
Ojo: el brief no pudo leer {{services}}; la lista puede estar incompleta.
<!-- @skipped.done -->
{{key}} ({{label}}, hecho el {{when}})
<!-- @skipped.declined -->
{{key}} (dijiste que no el {{when}})
<!-- @skipped.later -->
{{key}} (pospuesto hasta el {{until}})

<!-- @action.test -->
verificar la versión de {{instance}} y, si ya tiene el cambio, probar
<!-- @action.comment -->
dejar un comentario en el ticket (te muestro el texto antes de publicarlo)
<!-- @action.answer -->
leer los últimos comentarios y responder en el ticket (te muestro el texto antes)
<!-- @action.teams -->
escribirle a {{who}} por {{chat}} (te muestro el mensaje; lo enviás vos)
<!-- @action.writeTests -->
escribir sus casos de prueba a partir de la especificación
<!-- @action.finishTests -->
terminar los tests en borrador
<!-- @label.test -->
verificación de {{instance}}
<!-- @label.comment -->
comentario en {{board}}
<!-- @label.answer -->
respuesta en {{board}}
<!-- @label.teams -->
mensaje de {{chat}}
<!-- @label.writeTests -->
casos de prueba
<!-- @label.finishTests -->
tests en borrador
<!-- @who.person -->
{{name}}
<!-- @who.unknown -->
quien desarrolló el cambio (no sé quién es: decime a quién)

<!-- @reason.retest-ready -->
El arreglo ya está en {{instance}} (versión {{version}}){{via}}.
<!-- @reason.missing-info -->
Está en {{status}}: alguien espera datos tuyos.
<!-- @reason.test-ready -->
{{instance}} ya tiene el cambio (versión {{version}}){{via}}.
<!-- @reason.retest-waiting -->
Espera retest, pero {{instance}} tiene {{version}} y {{arrives}}. Conviene dejar dicho en el ticket que el retest espera esa versión.
<!-- @reason.test-waiting -->
{{instance}} todavía no tiene el cambio (tiene {{version}}; {{arrives}}): probar ahora daría un falso negativo.
<!-- @reason.retest-no-fix -->
Espera retest, pero no encuentro commits del arreglo, ni en el ticket ni en sus historias vinculadas.
<!-- @reason.no-tests -->
Todavía no tiene tests vinculados.
<!-- @reason.draft-tests -->
Tiene tests vinculados en borrador ({{tests}}).
<!-- @reason.dc-stalled -->
Lleva {{days}} días en {{status}} sin movimiento.
<!-- @reason.other -->
Cumple tu regla «{{rule}}».

<!-- @arrives.version -->
lo tendrá desde la versión {{firstVersion}}
<!-- @arrives.branch -->
el cambio todavía no llegó a {{branch}}
<!-- @arrives.unknown -->
no sé desde qué versión lo tendrá
<!-- @qa.via -->
; el cambio llegó por {{keys}}
<!-- @tests.none -->
ninguno
<!-- @tests.counts -->
{{total}}: {{byStatus}}
<!-- @tests.status -->
{{count}} {{status}}

<!-- @outcome.done -->
hecho
<!-- @outcome.declined -->
no
<!-- @outcome.later -->
para más tarde
<!-- @history.title -->
## Lo que anoté
<!-- @history.line -->
- {{when}} · [{{key}}]({{link}}) · {{label}} · {{outcome}}{{note}}
<!-- @history.none -->
Todavía no anoté nada.
<!-- @record.ok -->
Anotado: {{key}}, {{label}}, {{outcome}}.
