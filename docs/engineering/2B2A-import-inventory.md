# 2B2A2 inventory refresh at 9e60182

Initial checkout verified clean on `fix/cad-runtime-transaction-coordinator`,
HEAD `9e601824e83fd87b2cc646410975449ce6f316a8`. The historical inventory below
is retained as history, not as a description of the present native APIs.

The old native source/sink blocker has changed: OCCT now has BREP/STL sources
and BREP/STL sinks. `cad_occ_bridge` connects CAF sources to OCCT and captures
resources in custody. Its present API does not yet connect OCCT sinks to CAF
writer leases. This is required integration work, not evidence that native
serialization remains pathname-only.

## Current consumer map, before migration

| Consumer | Current authority/effects | 2B2A2 disposition |
|---|---|---|
| DesktopCadController.pickAndImport -> ImportEngine.execute | STL path import before runtime queue; source copy and import history writes | To migrate BREP/STL; not migrated yet |
| CadImportFormat / desktop picker | No BREP enum/entry; STL returns path-only XFile | Add explicit BREP entry and resolve source-capability contract |
| ImportEngine STEP/IGES | Native shape path import | Outside BREP/STL scope |
| DesktopCadController.restoreProjectGeometry | history.jsonl fallback reimports registered STL pathname | Explicit compatibility for old documents only |
| CadRuntime.registerImport | Selection/transient changes before mutate admission | Do not reuse for managed producers |
| CadRuntime._loadedShape / officialExportShape | Restores BREP from NativeShapes | Managed asset branch required; retain legacy branch for old entities |
| CadRuntime._persistNativeShape / persistShape | Writes NativeShapes BREP | New BREP/STL must never enter this branch |
| CadDocumentSceneProjection.synchronize / synchronizeChanges | Calls display pipeline whenever shape exists | Managed projection required for import, open and Redo |
| KernelDisplayMeshPipeline.upsert | BREP persist/restore, STL generation to DisplayMeshes, STL path reimport | New managed entities must bypass this whole pipeline |
| MeshApi / MeshEngine.importStl,reload | Independent mesh path import, checksum reopening and repository writes | Separate API consumer; must not be silently advertised as migrated |
| FEL mesh OPEN/IMPORT STL | MeshApi delegation | Default native_commands wiring injects UnavailableGeometryKernel; independently injected kernels still use legacy MeshEngine |
| FEL kernel STEP/IGES import | Native path interchange, state.current | Outside current scope |
| ExportEngine STL | Shape tessellation to export pathname | Export, outside import migration |
| OperationalReverseEngineeringController persistShape callers | Persistent shapes from other producers | Pending other producer sub-blocks; unchanged |
| OpenCascadeRuntimeRepository | Legacy NativeShapes directories and JSON metadata | Unmanaged legacy utility |
| ProjectRepository directory list | Creates legacy NativeShapes folder | Directory provisioning is not an import consumer; unchanged |
| OpenCascadeKernelAdapter / OpenCascadeFFI legacy methods | importFile, restoreShape, persistShape, importStl, mesh | Preserve ABI for legacy consumers; instrument zero usage in new managed flows |
| native flcad_occ_import_shape/import_stl/export_shape/mesh | Legacy C pathname APIs | Retain; new producers must use stream APIs instead |
| Native and Dart tests calling legacy APIs | Legacy regression and stream-equivalence tests | Test, not a productive migration escape |

## Representation and composition confirmed in current code

STL does not require shape: CadDocumentEntity and ImportedCadDocument have
independent optional shape/mesh fields. A managed STL must remain mesh-only and
must not claim a BREP. BREP needs its actual kernel BREP plus display STL assets.
The document can carry durable asset IDs; native owners/tokens belong exclusively
to the runtime custody table, outside JSON/history snapshots.

One internal transaction must compose staging, candidate/history/projection,
promotion and document installation. Public withGeometryStaging/mutate/
registerImport cannot be nested. Existing staging attachment transfers ownership
and disposes attached resources even after asset promotion: it is not an owner
handoff to the document. Transfer must occur after confirmed document commit.
The wrapper also validates the old runtime revision after callback return;
composition must recognize an actual committed document, not mislabel it stale.

Undo/open/Redo require managed asset reads and candidate owners before install.
Only after installation may old nonreferenced owners be released. A failure
following a real document commit must retain possibly referenced resources.

## Source selection contract selected for 2B2A2

The installed Windows picker returns a pathname, not a held object identity.
The selected design opens it exactly once through CAF when the runtime admits
the import. No Dart pre-read, validation, hash, format detection or later reopen
is permitted. CAF's file capability, identity, size and source C-to-C ABI are
then the only read authority; the locator is retained only for presentation.

**Guarantee:** “A importação corresponde ao objeto aberto pelo CAF no momento
da admissão. O picker atual não fornece identidade/handle, portanto não existe
garantia de identidade entre a exibição do picker e a abertura inicial.”

If a locator is replaced before CAF opens it, the operation either imports or
rejects the object actually opened and makes no claim about the picker object.
If replacement happens after CAF opens it, the anchored handle remains in use;
CAF identity/page hash/final SHA checks reject material change rather than
following the new directory entry. A future Windows picker may return a handle
or CAF capability at confirmation time to harden the pre-open interval. That
picker is explicitly outside 2B2A2.

Three independent readonly preliminary reviews confirmed this consumer map,
mesh-only STL support, required staging composition and ownership boundaries.
They are architecture reviews, not approval of a completed migration.

---

# 2B2A — inventário prévio de importação e impedimento de contrato

Base inspecionada: `f275adfeec142223bd31d376ebcc9407c97ad2c7`, branch
`fix/cad-runtime-transaction-coordinator`, inicialmente limpa. Data: 2026-09-09.
As referências de linha abaixo correspondem a essa base.

**Estado: inventário concluído; protocolo e migração não implementados.**
Este documento não aprova 2B2A, não modifica a aprovação interna do gate 2B1B
e não autoriza iniciar 2B2B. O teste entre dois volumes NTFS reais continua
pendente para liberação pública; não foi substituído por mock.

## Resultado da condição prévia

O pedido condiciona a implementação à ausência de impedimento arquitetural.
Há uma lacuna na fronteira produtiva OpenCascade: a tesselação de um shape
só entrega o display por escrita de STL em um pathname. A persistência BREP
também só oferece saída por pathname. Não há saída em stream, bytes ou
capacidade de arquivo nessa interface.

Evidências:

- `lib/core/cad_kernel/opencascade/open_cascade_bridge.dart:28,43`:
  `exportShape(token, path, ...)` e `mesh(token, outputPath, ...)`.
- `native/opencascade/include/flcad_occ_api.h:39,42`:
  `flcad_occ_export_shape` e `flcad_occ_mesh` recebem `const char* path`.
- `native/opencascade/src/flcad_occ_api.cpp:1704,1811`: respectivamente
  `BRepTools::Write(s, p)` e `StlAPI_Writer::Write(s, p)`.
- `flcad_occ_mesh_geometry` (`flcad_occ_api.cpp:805`) lê o registry de meshes
  já importadas, não tessela um shape BREP em memória.
- `lib/app/runtime/cad_asset_staging.dart:400`: a entrada externa do staging
  é borrowed e somente seu stream entra na capacidade segura de escrita.

Copiar o BREP original via staging pode preservar o source, mas não produz
o display do shape. Gerar esse display em arquivo temporário e copiá-lo
depois não atende à geração exclusivamente pelo staging. Manter handles
do helper e entregar um pathname ao OpenCascade tampouco transforma a chamada
OpenCascade em escrita relativa à capacidade.

Isto é um impedimento para compor **os contratos atuais**, não uma afirmação
de impossibilidade técnica nem de que o pedido proíba estender a ABI. Uma
extensão produtiva isolada de tesselação/serialização em memória ou stream
pode resolvê-lo. Ela precisa tratar ownership do resultado, erro pós-criação,
cancelamento e lifecycle antes de a migração completa poder ser comprovada.
Nenhum substituto exclusivamente simulado foi implementado como solução.

## Entradas e roteamento

| Entrada | Caminho atual | Situação |
|---|---|---|
| Importação STL desktop | `desktop_application.dart:711` → `desktop_command_coordinator.dart:169` → `DesktopCadController.pickAndImport:41` → `ImportExportApi.import:120` → `ImportEngine.execute:18` | Produtiva, unmanaged antes da fila documental |
| STEP/IGES que criam shapes BRep | Mesmo controller/engine; `ImportEngine:51` chama `importFile` | Produtiva; não confundir formatos STEP/IGES com arquivo `.brep` |
| Arquivo BREP | `OpenCascadeKernelAdapter.importFile:194`, `KernelExchangeFormat.brep` | Disponível na API de kernel; não há entrada `.brep` no picker ou `CadImportFormat` |
| Restauração de shape BREP | `OpenCascadeKernelAdapter.restoreShape:229`, runtime `_loadedShape:809`, display pipeline | Registra token unmanaged; usa `NativeShapes` |
| Restauração STL legada | `DesktopCadController.restoreProjectGeometry:147–200` | Depois de open, fallback de `CAD/ImportHistory/history.jsonl`, nova importação/inspeção e `registerImport` |
| MeshFoundation | `MeshApi.importStl:8` → `MeshEngine.importStl:24`; `reload:86` | API programática independente do CadRuntime, unmanaged |
| FEL OPEN STL / IMPORT STL | `fel_mesh_commands.dart:20–23` → MeshApi | Registro padrão em `native_commands.dart:497` usa `UnavailableGeometryKernel`; não é rota produtiva desktop nesse wiring |
| FEL IMPORT STEP / IGES | `fel_kernel_commands.dart:171–180,251–252` | Cria shape e atualiza `state.current` fora do CadRuntime; não registra IMPORT BREP |
| STL auxiliar de exibição | `KernelDisplayMeshPipeline.upsert:41–131` | Tessela shape, grava STL, importa mesh, inspeciona e fecha mesh temporária |

`CadImportFormat` (`import_export_api.dart:11`) contém somente stl, step,
iges, obj e ply. OBJ/PLY chegam à enum, mas `ImportEngine` os rejeita como
não expostos pelo kernel oficial. A futura entrada BREP precisa ser adicionada
explicitamente e preservada na leitura documental; não é uma rota UI já migrada.

## Sequência de efeitos, awaits e posse atual

| Etapa | Efeito e autoridade atual | Await/callback e falha posterior possível |
|---|---|---|
| Escolha de arquivo | Controller captura projeto antes do picker; source externo borrowed | Picker, resolução do diretório e `runtime.open`; projeto pode ter mudado |
| Validação | `ImportValidation.validateFile`; nenhum owner nativo | Leitura/validação pode falhar; source não é snapshot imutável |
| Importação shape | Adapter `importFile:194` chama bridge; `_handle:156` registra unmanaged e associa token a persistentId | `runtime.run`, `_legacyOperation`, import nativo; erro posterior não tem owner transacional de produtor |
| Importação STL | Adapter `importStl:273–316` recebe token, registra unmanaged, cria `KernelMeshHandle` | Mesmo desacoplamento; falha em inspeção/cópia não desfaz criação |
| Retorno da FFI | Buffers/pointers são locais; token identifica entrada no registry nativo | `OpenCascadeFFI:956,1010` chama progresso 100% depois da syscall e antes do retorno do recurso; callback lançando impede entrega à custody |
| Diagnóstico/inspeção | Engine diagnostica shape; controller inspeciona mesh via API legada | `diagnose`/`inspectMesh` podem falhar após alocação; não usam leases do 2B1A |
| Registro de source | Repository cria pastas e copia para `CAD/Imports/<basename>` | `exists` seguido de `File.copy`; colisão, sharing/IO ou source alterado deixam efeitos separados |
| Registro de histórico | `recordImport` faz append de ImportHistory e RecentFiles | Segundo append pode falhar depois do primeiro; não há rollback junto ao documento |
| Registro no runtime | `registerImport:328` limpa transientes, seleção e chaves de estado; calcula nome/ID antes da fila | `mutate` é o primeiro ponto de admissão; erro pode ocorrer com seleção já alterada |
| Candidato documental | `_mutateDocument:447` captura snapshot, aplica delta e valida associações/dependências | Erro rejeita candidato; efeitos anteriores do importador permanecem |
| Candidato de cena | `_commitDocument:295` chama `_prepareScene` em cena temporária | Projeção de shape chama pipeline que escreve BREP/STL legados; falha não equivale a desfazer esses arquivos |
| Persistência | `_persistSnapshot:253` captura arquivos, salva documento e histórico | Valida tx após awaits; em falha tenta restaurar bytes; restauração falhando gera `CadRecoveryFailure` e bloqueio do runtime |
| Instalação | `_install:335` instala documento, histórico, cena e seleção filtrada; marca `tx.committed` | Síncrona; parse/mesh ocorreram antes. Recursos nativos ainda não têm owner documental managed |
| Notificação | `_enqueue` publica após revogar capability; falhas observacionais são reportadas | `registerImport:407–412` ainda altera import ativo/bounds e notifica depois de `mutate`, fora dessa proteção |

Tokens nativos ficam nos maps privados `_nativeTokens` e `_nativeMeshTokens`
do adapter e no registry C++; `ShapeHandle`/`KernelMeshHandle` carregam
referências portáveis, não autoridade destrutiva. A mera referência persistente
não prova que o payload existe, nem concede lease. `restoreShape` continua
registrando unmanaged.

No caminho MeshFoundation, o checksum FNV é calculado depois da criação
nativa; depois são alterados repository, diagnostics, history, analytics e
integration (`mesh_engine.dart:47–81`). `reload` fecha a mesh anterior antes
de tentar importar a nova. Não participa de snapshots/Undo do CadRuntime.

## Escritas atuais e leitores que as reativam

| Local | Escrita | Reativação/risco |
|---|---|---|
| `ImportExportRepository:24–80` | Pastas `CAD/Imports`, source copiado, ImportHistory e RecentFiles | Antes do commit; nome vem do basename do usuário |
| `KernelDisplayMeshPipeline:59–90` | `NativeShapes/<id sanitizado>.brep`, `DisplayMeshes/<id sanitizado>.stl` | Projeção sempre chama pipeline para shape, mesmo com `sceneGeometry` pronta |
| `CadRuntime._persistNativeShape:831` | BREP em `NativeShapes` | Upsert, transformações e outros produtores legados |
| `OpenCascadeRuntimeRepository:10` | Pastas Kernel/KernelCache/KernelDiagnostics/NativeShapes; JSON de metadata e diagnóstico | Utilitário legado; não é gateway de assets |
| `CadDocumentRepository:117–140` | Temporário, exclusão do destino e rename por pathname | Documento/histórico separados, rollback somente em processo |
| `MeshRepository.persist` | Metadados/histórico/diagnóstico MeshFoundation | Persistência independente do documento CAD |

`CadDocumentSceneProjection.synchronize:48` e `synchronizeChanges:97`
reexecutam o pipeline para shapes em open/Undo/Redo. `officialExportShape:140`
e `_loadedShape:809` procuram payload em `NativeShapes`; não resolvem asset ID.
Logo, alterar somente o controller não elimina writes legados de uma importação.

O repositório documental declara expressamente que os dois JSONs não são
crash-atômicos (`cad_document_repository.dart:73`). A interpretação literal
de “nenhuma mutação por pathname nos fluxos migrados” exige também resolver
essa fronteira documental. Migrar somente payloads não muda o backend de
persistência de documento/histórico.

## Contratos a compor após resolver a fronteira nativa

Estas são lacunas de integração implementáveis, não novos impedimentos absolutos:

1. Admitir toda a importação uma única vez em `_enqueue`, antes da criação
   nativa. Capturar source/request e validar documento, sessão, revisão e
   lifecycle antes de cada efeito. `withGeometryStaging` hoje admite sua própria
   transação; precisa de composição interna com a mesma tx, sem fila aninhada.
2. Importar shape/mesh diretamente para custody, sem callbacks entre a criação
   nativa e o registro. Disponibilizar operações leased de inspeção/tesselação/
   serialização. `createOwnedShape`, `createOwnedMesh` e `diagnoseOwned` atuais
   não constituem essa API de importação.
3. Reter o owner no produtor até commit documental confirmado. Não usar
   `attachOwnedShape/Mesh` para retenção documental: transfere na preparação
   e `_finishWork:727` dispõe os owners anexados mesmo após promoção.
4. Produzir source/BREP/display pelo staging, seal e verificar identidade,
   volume, tamanho e SHA-256. Promover por helper, sem overwrite. Não entregar
   path de staging como autoridade de escrita ao OpenCascade.
5. Preparar candidato documental e projeção managed antes de instalar;
   evitar a geração legada na projeção managed, inclusive na reabertura e Undo.
6. Publicar somente após assets duráveis; distinguir `committed` do journal de
   assets da confirmação documental. `PreparedGeometryAssets.documentPublished`
   hoje é sempre false, por contrato do 2B1B.
7. Após confirmação documental, transferir owner ao runtime e preservar
   referências de Undo/Redo. Snapshot de seleção precisa de tratamento próprio:
   hoje Undo/Redo restauram documentos, mas só filtram a seleção atual.
8. Revogar antes de await em falha/cancelamento; drenar operações/leases,
   registrar syscall concluída sem fingir rollback. Notificação falhando depois
   de `tx.committed` não autoriza destruir recurso possivelmente referenciado.

## Ownership e recuperação exigidos, ainda não implementados para imports

| Estado do protocolo futuro | Owner e recuperação necessários |
|---|---|
| Admitido, antes de criar | Source borrowed; nenhuma autoridade para apagar source |
| Criado / produzindo | Owner exclusivo do produtor; cada acesso com lease; falha dispõe somente recurso comprovadamente não publicado |
| Preparado | Mesmo owner; payloads selados no staging; cancelamento não os publica |
| Parcialmente promovido | Registrar renames efetivos; preservar assets/staging e quarentenar; nenhuma exclusão compensatória |
| Promovido, commit recusado | Assets retidos para reconciliação; impedir publicação parcial; falha ambígua documental preserva recurso possivelmente referenciado |
| Documento confirmado | Ownership transferido ao runtime; falha de notificação é observável, não rollback |
| Close/shutdown | Revogar admissão e aguardar operação/leases; dispose idempotente; falha de dispose gera quarentena observável |

Hoje `inspectCadAssetStaging` é conservador e somente leitura; assets promovidos
são `awaitingDocumentReconciliation`. Não há reconciliação com import documental
implementada. `CadRecoveryFailure` já mantém causa e stacks e bloqueia novas
transações quando o rollback documental não é verificável. Nenhum GC é necessário
para essa etapa e nenhum foi introduzido.

## Cobertura existente e pendências

As regressões de staging/custody/transações provam suas fundações separadas;
não provam uma importação transacional integrada. Os seis testes de
`professional_import_export_test.dart` usam kernel instrumentado para roteamento
e validação; não demonstram geração BREP segura. Testes de persist/restore em
`opencascade_integration_test.dart` tampouco incluem commit documental e custody.

Continuam pendentes para a futura implementação TODOS os testes integrados
2B2A solicitados: import BREP/STL; falhas antes/depois da criação, mesh, staging,
seal, promoção, projeção, persistência e instalação; cancelamento em fronteiras;
troca de documento/sessão; FIFO com conclusão invertida; shutdown com lease;
commit recusado depois da promoção; notificação após commit; Undo/Redo com
seleção; save/close/open; manifests/hashes; ausência de double-free/UAF e de
escrita por pathname. Não foram contados como aprovados por testes da fundação.

## Revisões independentes somente leitura

- Atomicidade documento/assets/histórico: confirmou efeitos anteriores à fila,
  reativação do pipeline na projeção, seleção fora do snapshot e persistência
  documental separada. Diferenciou lacuna nativa de impossibilidade absoluta.
- Ownership/leases/lifecycle: confirmou saída nativa somente por pathname,
  callback pós-criação antes de custody, importação unmanaged e incompatibilidade
  do attach/finish atual com owner documental persistente.
- Falhas/rotas alternativas: confirmou ausência da entrada BREP UI, fallback
  STL legado e API MeshFoundation independente; corrigiu que o FEL padrão usa
  kernel indisponível, não o kernel produtivo desktop.

São revisões do inventário e da base, não aprovação de código 2B2A. Nenhuma
operação foi migrada. Todas as rotas existentes permanecem como estavam,
unmanaged; transformações, primitivas, extrusão, superfícies, interseções,
duplicações e GC não foram alterados.

## Validação desta entrega documental

- `flutter --suppress-analytics analyze --no-pub`: exit 0, sem problemas.
- `flutter --suppress-analytics build windows --release --no-pub -t lib/main.dart`:
  exit 0, aplicativo completo gerado em 17,0 s. Nenhuma geometria produtiva
  foi processada; nenhum aplicativo foi iniciado para simular importação 2B2A.
- `dart format --output=none --set-exit-if-changed` nos quatro arquivos de
  runtime/gateway e quatro testes de fundação examinados: 8 arquivos,
  zero alterações. O único arquivo novo é Markdown.
- Regressões direcionadas: staging 61, gateway 12, custody 30, transações 42,
  import/export legado 6 — 151 casos distintos com resultado aprovado ao final.
  Comando inicial: `flutter --suppress-analytics test --no-pub
  test/cad_asset_staging_test.dart test/cad_asset_fs_gateway_test.dart
  test/native_allocation_custody_test.dart test/cad_runtime_transaction_test.dart
  test/professional_import_export_test.dart --reporter expanded`.
- A primeira execução teve 150 aprovações e uma falha de preparação: a DLL
  do smoke bundle foi selecionada, mas essa pasta não contém
  `cad_asset_fs_incompatible.dll`, exigida pelo teste negativo de ABI.
  Gateway foi repetido inteiro com `FLCAD_CAD_ASSET_FS_DLL` apontando para
  `build/cad_asset_fs/Debug/cad_asset_fs.dll`, ao lado da DLL incompatível:
  12/12 aprovados, exit 0. Não foi alterado teste para aceitar a falha.
- Logs locais ignorados: `build/cad_asset_fs/2b2a-inventory-tests.log`,
  `2b2a-inventory-gateway-retry.log`, `2b2a-inventory-analyze.log` e
  `2b2a-inventory-windows-build.log` no mesmo diretório.
- `git diff --check`: sem problemas; nenhum código de produção ou teste
  alterado. Revisões do documento sem achados críticos, altos ou médios;
  pequenas imprecisões de referência de linha corrigidas.

Build/testes da base não eliminam a lacuna da ABI nem constituem prova da
migração. **Recomendação: não iniciar 2B2B; resolver a fronteira nativa e concluir
o protocolo/importação e seus testes integrados do 2B2A primeiro.**
