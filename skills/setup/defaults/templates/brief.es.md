Plantilla del brief, versión del equipo en español. Viene con el kit; si la editás en tu copia instalada, una actualización respeta tu versión y te propone combinarla con la nueva.

Cada texto empieza con una línea que tiene solo `<!-- @nombre -->` y sigue hasta el próximo. `{{dato}}` se reemplaza por un dato; un dato que no existe queda vacío. Este párrafo no se usa.

Para cambiar un texto solo para vos, en vez de editar este archivo conviene escribir en tu plantilla propia (`paths.templates.brief` en la configuración) solo los textos que cambiás, cada uno con su misma línea `@nombre`. Los tuyos ganan; los que no escribas siguen saliendo de acá, y tu plantilla nunca hay que combinarla al actualizar.

<!-- @format.culture -->
es-AR
<!-- @format.when -->
dddd d 'de' MMMM, HH:mm
<!-- @format.date -->
dd/MM
<!-- @format.dateTime -->
dd/MM HH:mm

<!-- @brief -->
# Brief de {{user}} · {{date}}

{{sections}}
<!-- @section -->
## {{title}}
{{body}}

<!-- @title.attention -->
Lo importante
<!-- @title.changes -->
Qué cambió desde el brief anterior
<!-- @title.instances -->
Versión de cada instancia
<!-- @title.pullRequests -->
Mis PR abiertos
<!-- @title.merged -->
Mis PR mergeados en los últimos {{days}} días
<!-- @title.worktrees -->
Mis worktrees

<!-- @attention.item -->
- {{text}}
<!-- @attention.none -->
- Nada urgente.
<!-- @attention.unreachable -->
No pude conectarme a {{service}} (¿VPN?): lo que depende de eso falta en este brief.
<!-- @attention.refused -->
{{service}} rechazó tus credenciales: corré /setup para revisarlas.
<!-- @attention.noClone -->
No hay clon del repositorio de código, así que no puedo ver qué tiene cada instancia: /setup, paso 5.
<!-- @attention.qaReady -->
[{{key}}]({{link}}) · {{summary}} ({{status}}): {{instance}} ya tiene el cambio (versión {{version}}). Se puede probar.
<!-- @attention.qaWaiting -->
[{{key}}]({{link}}) · {{summary}} ({{status}}): {{instance}} todavía no tiene el cambio (tiene {{version}}); {{arrives}}.
<!-- @attention.qaNone -->
[{{key}}]({{link}}) · {{summary}} ({{status}}): no encontré commits del cambio, ni del ticket ni de sus historias vinculadas.
<!-- @attention.qaUnknown -->
[{{key}}]({{link}}) · {{summary}} ({{status}}): no pude saber si {{instance}} tiene el cambio ({{why}}).
<!-- @attention.qaSkipped -->
Verifiqué {{max}} tickets contra {{instance}}; {{count}} quedaron sin verificar por el límite de la configuración.
<!-- @attention.changes -->
{{count}} cambio(s) en tus vistas desde el brief anterior (abajo).
<!-- @attention.prFailed -->
PR #{{id}} ({{title}}) falló en {{checks}}.
<!-- @attention.prConflict -->
PR #{{id}} ({{title}}) tiene conflictos con {{target}}.
<!-- @attention.prSonar -->
PR #{{id}} ({{title}}) no pasó {{quality}}: {{why}}.
<!-- @attention.prStale -->
PR #{{id}} ({{title}}) está {{behind}} commit(s) atrás de {{target}}: hay que rebasear.
<!-- @attention.prNeedsWork -->
PR #{{id}} ({{title}}) tiene pedidos de cambios.
<!-- @attention.unpushed -->
El worktree {{name}} tiene {{count}} commit(s) sin pushear.
<!-- @attention.noBitbucketToken -->
Falta el token de {{repo}} ({{variable}}), así que no leí tus PR: /setup, paso 7.

<!-- @changes.first -->
- Es el primer brief: desde el próximo, acá aparece lo que cambió.
<!-- @changes.since -->
Desde el brief anterior ({{when}}):
<!-- @changes.new -->
- [{{key}}]({{link}}) apareció en "{{view}}" ({{status}}).
<!-- @changes.status -->
- [{{key}}]({{link}}) pasó de {{from}} a {{to}} ("{{view}}").
<!-- @changes.newMany -->
- {{count}} tickets nuevos en "{{view}}": {{keys}}.
<!-- @changes.gone -->
- {{key}} ya no está en "{{view}}" (estaba en {{status}}).
<!-- @changes.goneMany -->
- {{count}} tickets ya no están en "{{view}}": {{keys}}.
<!-- @changes.none -->
- Nada cambió en tus vistas.

<!-- @view.empty -->
Nada por acá.
<!-- @view.more -->
Se muestran los primeros {{count}}; hay más en {{board}}.
<!-- @view.badJql -->
{{board}} rechazó la consulta de esta vista; /setup (paso 6) la revisa.
<!-- @view.unreachable -->
No pude leer esta vista de {{board}}.

<!-- @column.key -->
Ticket
<!-- @column.qa -->
¿En {{instance}}?
<!-- @column.tests -->
Tests vinculados
<!-- @field.summary -->
Qué es
<!-- @field.status -->
Estado
<!-- @field.priority -->
Prioridad
<!-- @field.assignee -->
Asignado a
<!-- @field.reporter -->
Reportado por
<!-- @field.updated -->
Actualizado
<!-- @field.created -->
Creado
<!-- @field.issuetype -->
Tipo

<!-- @qa.IN -->
sí ({{version}}{{via}})
<!-- @qa.NOT_IN -->
no; {{arrives}}{{via}}
<!-- @qa.NONE -->
sin commits del cambio
<!-- @qa.UNKNOWN -->
no se sabe ({{why}})
<!-- @qa.skipped -->
sin verificar (límite)
<!-- @qa.notAsked -->
no se consulta en este estado
<!-- @qa.via -->
, por {{keys}}
<!-- @arrives.version -->
lo tendrá desde la versión {{firstVersion}}
<!-- @arrives.branch -->
todavía no llegó a {{branch}}
<!-- @arrives.unknown -->
no sé desde qué versión lo tendrá
<!-- @why.noClone -->
falta el clon del repositorio
<!-- @why.unreachable -->
{{cd}} no responde
<!-- @why.noVersion -->
no se pudo leer su versión
<!-- @why.versionCommit -->
no encontré el commit de su versión
<!-- @why.error -->
{{cd}} dio una respuesta inesperada

<!-- @tests.none -->
ninguno
<!-- @tests.counts -->
{{total}}: {{byStatus}}
<!-- @tests.status -->
{{count}} {{status}}

<!-- @check.IN -->
[{{key}}]({{link}}): {{instance}} ya tiene el cambio (versión {{version}}){{via}}. Se puede probar.
<!-- @check.NOT_IN -->
[{{key}}]({{link}}): {{instance}} todavía no tiene el cambio (tiene {{version}}){{via}}; {{arrives}}.
<!-- @check.NONE -->
[{{key}}]({{link}}): no encontré commits del cambio, ni del ticket ni de sus historias vinculadas.
<!-- @check.UNKNOWN -->
[{{key}}]({{link}}): no pude saber si {{instance}} tiene el cambio ({{why}}).

<!-- @instances.line -->
- {{name}}: {{version}}{{qa}}{{upgrade}} ({{source}})
<!-- @instances.qa -->
 · la usa QA
<!-- @instances.upgrade.manual -->
 · se actualiza a mano
<!-- @instances.upgrade.auto -->
 · se actualiza sola con cada publicación
<!-- @instances.unknown -->
- {{name}}: no pude leer su versión.
<!-- @instances.unreachable -->
- No pude conectarme a {{cd}} (¿VPN?).
<!-- @source.publisher -->
según la actualización #{{build}}, {{when}}
<!-- @source.live -->
leída en vivo de su dirección

<!-- @pr.none -->
- No tenés PR abiertos.
<!-- @pr.noToken -->
- Falta el token de {{repo}} ({{variable}}); /setup, paso 7, explica cómo guardarlo.
<!-- @pr.unreachable -->
- No pude conectarme a {{repo}} (¿VPN?).
<!-- @pr.refused -->
- {{repo}} rechazó el token ({{variable}}): puede estar vencido. /setup, paso 7.
<!-- @pr.head -->
### [PR #{{id}}]({{link}}) · {{title}} · a {{target}}{{repo}} · {{verdict}}
<!-- @pr.repo -->
 (repo {{repo}})
<!-- @pr.jenkins -->
- {{checks}}: {{state}}{{build}}{{link}}
<!-- @pr.sonar -->
- {{quality}}: {{text}}{{link}}
<!-- @pr.review -->
- Revisión: {{text}}
<!-- @pr.merge -->
- Merge: {{text}}
<!-- @pr.branch -->
- Rama: {{text}}
<!-- @verdict.green -->
VERDE
<!-- @verdict.running -->
CORRIENDO
<!-- @verdict.failed -->
FALLA
<!-- @verdict.attention -->
ATENCIÓN
<!-- @verdict.noBuild -->
SIN BUILD
<!-- @jenkins.ok -->
OK
<!-- @jenkins.failed -->
FALLÓ
<!-- @jenkins.running -->
corriendo
<!-- @jenkins.none -->
sin build todavía
<!-- @jenkins.other -->
{{state}}
<!-- @jenkins.build -->
 build #{{n}}
<!-- @jenkins.link -->
 ([{{checks}}]({{url}}))
<!-- @sonar.pass -->
pasó
<!-- @sonar.fail -->
no pasó: {{why}}
<!-- @sonar.none -->
sin reporte
<!-- @sonar.pending -->
todavía sin reporte (el build no terminó)
<!-- @sonar.link -->
 ([{{quality}}]({{url}}))
<!-- @review.none -->
sin revisores asignados
<!-- @review.count -->
{{approved}} de {{total}} aprobaron
<!-- @review.needsWork -->
; pidieron cambios: {{who}}
<!-- @merge.ok -->
sin conflictos ni bloqueos
<!-- @merge.conflict -->
tiene conflictos con {{target}}
<!-- @merge.vetoed -->
bloqueado: {{why}}
<!-- @merge.unknown -->
no pude consultarlo
<!-- @branch.behind -->
{{behind}} commit(s) atrás de {{target}}. {{checks}} puede fallar en segundos con "Committer identity unknown"; hay que rebasear sobre origin/{{target}}.
<!-- @branch.upToDate -->
al día con {{target}}

<!-- @merged.none -->
- No mergeaste PR a {{branches}} en los últimos {{days}} días.
<!-- @merged.line -->
- [PR #{{id}}]({{link}}) · {{title}} · a {{target}}, {{when}} · {{instances}}
<!-- @merged.in -->
{{name}}: sí
<!-- @merged.notIn -->
{{name}}: no
<!-- @merged.unknown -->
{{name}}: no se sabe
<!-- @merged.notFound -->
- [PR #{{id}}]({{link}}) · {{title}}: todavía no lo veo mergeado en git.
<!-- @merged.noClone -->
- Sin el clon del repositorio no puedo ver en qué instancia está cada PR.
<!-- @merged.more -->
- y {{count}} más.

<!-- @worktree.none -->
- No hay worktrees aparte del checkout principal.
<!-- @worktree.noClone -->
- No hay clon del repositorio de código configurado.
<!-- @worktree.line -->
- {{name}} ({{branch}}): {{parts}}
<!-- @worktree.missing -->
- {{name}}: la carpeta no existe; git todavía lo tiene registrado.
<!-- @worktree.detached -->
- {{name}}: sin rama (HEAD suelto).
<!-- @worktree.target -->
destino {{target}} ({{from}})
<!-- @worktree.noTarget -->
destino desconocido (sin PR)
<!-- @worktree.ahead -->
{{count}} commit(s) propios
<!-- @worktree.behind -->
{{count}} atrás de {{target}}
<!-- @worktree.upToDate -->
al día con {{target}}
<!-- @worktree.unpushed -->
{{count}} commit(s) sin pushear
<!-- @worktree.pushed -->
todo pusheado
<!-- @worktree.neverPushed -->
la rama nunca se pusheó
<!-- @worktree.dirty -->
{{count}} archivo(s) sin commitear
<!-- @worktree.clean -->
limpio
<!-- @from.openPr -->
PR #{{id}} abierto
<!-- @from.mergedPr -->
PR #{{id}} ya mergeado
