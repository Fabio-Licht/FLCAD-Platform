# STEP-1A1: importação transacional managed

Base: HEAD limpo `b45ce8d`, branch `fix/cad-runtime-transaction-coordinator`.
A fronteira C→C continua sendo a aprovada em
[STEP_SOURCE_STREAM.md](../../native/opencascade/STEP_SOURCE_STREAM.md). Nenhuma
assinatura, layout ou versão de ABI nativa foi alterada.

## Contrato implementado

`CadRuntime.importManagedStep(locator, cancellation: ...)` consome o locator por
`CadAssetNativeFs.openExternal` antes de entrar na fila. Depois da admissão, somente
objeto CAF, identidade selada e capabilities transitórias autorizam leitura.
`cob_begin_v1`, kind 3, e `cob_step_run_v1` executam em bridge C→C; Dart não recebe
blocos STEP, BREP ou STL. O worker devolve somente metadados limitados. O shape é
registrado em custody e adotado do escrow antes de decodificar/aplicar metadados
ou chamar observadores. As bibliotecas permanecem residentes, com anchors nativos.

São aceitos os limites do leitor STEP-1A0: arquivo Part21 único, uma peça sólida,
sem assembly, referências externas ou transparência. Não há reader legado,
`ReadFile`, reabertura por pathname ou arquivo temporário de conversão. O staging
e os temporários do journal seguem o protocolo CAF já aprovado.

`ManagedStepAssets` é independente de `ManagedBrepAssets` e `ManagedStlAssets`:

```json
{
  "schema": "flcad.managed-step-assets",
  "version": 1,
  "sourceFormat": "step",
  "meshOnly": false,
  "shapeAssetId": {"schema": "flcad.geometry-asset", "version": 1, "id": "ga1_<32hex>"},
  "shapeSha256": "<64hex>",
  "displayMeshAssetId": {"schema": "flcad.geometry-asset", "version": 1, "id": "ga1_<32hex>"},
  "displayMeshSha256": "<64hex>",
  "appearanceManifestAssetId": {"schema": "flcad.geometry-asset", "version": 1, "id": "ga1_<32hex>"},
  "appearanceManifestSha256": "<64hex>"
}
```

Os três IDs são distintos. Chaves extras, versões/tipos errados, hashes inválidos,
refs ambíguas e combinação com contratos BREP/STL são recusados. A entidade não
persiste shape/mesh handles, sourceIdentity ou descritores/fingerprints residentes.
Seu nome lógico vem do XDE; unidade e aparência ficam no manifesto referenciado.
Campos de entidade STEP são limitados e dados transitórios são recusados inclusive
quando aninhados. Os contratos BREP direto e STL mantêm seu significado anterior.

## Manifesto e apresentação

Cada manifesto ocupa um asset próprio `appearance.json`, com descriptor CAF
`asset.json`, tamanho e SHA-256 verificados durante preparação e promoção.
`flcad.step-appearance` v1 contém, em ordem fixa:

- schema, version, name e declaredUnit;
- declaredMetersPerUnit, resolvedUnit=`mm` e resolvedMetersPerUnit=`0.001`;
- hasColor, colorSpace=`linear-srgb`, rootRgb e alpha.

O encoder emite JSON UTF-8 determinístico, converte os componentes para doubles
canônicos e normaliza zero. Cor presente exige três canais finitos [0,1] e alpha 1.
Cor ausente é `hasColor=false`, `rootRgb=null`, `alpha=null`; não inventa cinza.
O manifesto representa somente aparência da raiz única, ligada à entidade pelo
contrato dos três assets. Não usa label XDE, índice de face ou identidade nativa.

OCCT transfere a geometria para milímetros antes da publicação nativa. A escala
declarada é proveniência: Dart não escala shape ou nodes novamente. Fixtures em
metros e milímetros resultam em bounds 10×20×30 mm.

`prepareSceneGeometry` preserva `normalsOrigin=calculatedByAdapter`. Somente a
entidade com cor recebe `rootLinearRgb`. `cadRootSrgb` converte linear-sRGB para
canais sRGB de apresentação:

- Canvas: `_paintMeshBatched` usa `cadRootColor` como foreground, mantendo as
  precedências existentes de seleção, hover e previews;
- Windows: `CadSceneDisplayAdapter` envia `rootSrgb`; `NativeViewportHost`
  armazena a cor por entidade e atualiza `Constants.color` antes de cada
  `DrawIndexed`. Deltas de visibilidade preservam a cor existente.

O target Windows é UNORM e o shader conserva seu sombreamento aproximado existente;
isto não promete renderização física/PBR. Ausência de cor usa os defaults visuais
locais anteriores. Nem STL nem manifesto são recoloridos pelo renderer.

## Atomicidade e recuperação

Shape em custody produz BREP e display STL diretamente em writer CAF. A malha
selada é lida pelo source bridge e capturada em custody. Manifesto, assets, cena
e transferência conjunta shape+mesh são preparados antes da promoção. Publicação
documental/histórico precede instalação síncrona de retenção, cena e seleção.
Depois do commit, o journal confirma `documentPublished=true`.

Falhas pré-promoção drenam owners/leases, não publicam e preservam staging pelo
protocolo de quarentena. Falhas após promoção preservam os assets, registram
quarentena e não publicam entidade. Falha de persistência restaura os arquivos
documentais/histórico e mantém owners, cena e recursos anteriormente confirmados.
Falha de confirmação/cleanup após commit gera
`CadManagedStepPostCommitFailure` e `recoveryRequired=true`; não remove nem desfaz
o commit persistido. Recuperação automática do manifesto é escopo posterior.

Cancelamento explícito revoga a transação e o source nativo. Nova abertura e
shutdown reutilizam a revogação de lifecycle existente. Cada fronteira com await
valida a transação antes de promover/publicar. Não há aquisição recursiva da fila.

## Matriz de evidência

| Garantia | Evidência |
| --- | --- |
| Nome UTF-8, BREP + STL + manifesto, hashes e 2 owners | `cad_runtime_managed_step_test`: modos 0/1/2 |
| Cor efetiva na cena, Canvas e mensagem Windows | mesmos testes: `rootLinearRgb`, `cadRootColor`, `rootSrgb`; leitura do host e build Windows |
| Ausência explícita de cor | modo 1: manifesto null, nenhum campo de cor na cena/mensagem |
| Sem escala dupla | modo 2 em metro + modo 0 em mm: bounds 10×20×30 |
| Invalid/assembly/external sem publicação | modos 3/4/5: OCC_READ_FORMAT, estado e fonte intactos; gates nativos STEP-1A0 |
| Writer, manifesto e staging falhos | beforeShapeWrite, beforeDisplayWrite, beforeAppearance, file:chunkWritten; `flcad_occ_brep_stream_test` valida falhas reais de sink/exceções no mesmo writer nativo |
| Pré/pós-promoção e persistência | beforePromotion, afterPromotion, beforePersistence, journal committed e repository.save |
| Commit preservado quando confirmação falha | segundo flush committed: erro pós-commit, documento/owners presentes, recoveryRequired |
| Revogação determinística | Completers em beforePromotion: cancel, abertura substituta e shutdown |
| Assets anteriores íntegros | importação confirmada seguida por save rejeitado: hashes/tamanhos, documento/histórico e owners anteriores |
| Sem caminho legado/temporário de payload | contador nativo de path import, ausência de NativeShapes/DisplayMeshes e .tmp após sucesso; inspeção source/commit |
| Contratos estritos e compatibilidade | `managed_step_contract_test` + regressões BREP/STL/legado |

## Limites deliberados

Este documento registra STEP-1A1. A reabertura implementada posteriormente em
STEP-2A está descrita em [STEP managed open lifecycle](step-managed-open-lifecycle.md).
O bloqueio de open mencionado abaixo é histórico; Undo/Redo STEP continua fora
do escopo aprovado.

Esta fase importa e persiste, sem implementar restauração STEP. `save` e `close`
genéricos preservam os três assets e drenam a residência. Open de documento STEP
e alterações documentais/histórico enquanto há STEP são recusados explicitamente
com `UnsupportedError` referindo STEP-2, antes de publicação ou pipeline legado.
Não se declara que cores já sejam restauradas após reabertura. STEP-2 deverá
validar os três hashes, decodificar o manifesto, reconstruir BREP+mesh em custody
e aplicar a mesma apresentação antes de publicar open/Redo atomicamente.

Sem comando visual/menu, assemblies, externos, corpo/face, transparência,
textura/PBR/PMI, GC ou 2B2B. BREP permanece geométrico e não é substituído por STL;
comandos de edição sobre a residência managed não são adicionados aqui.
Cancelamento OCCT continua cooperativo; não há sandbox rígido de CPU/memória.

## Revisões somente leitura

1. Atomicidade, documento e aparência: seguidas as fronteiras source/custody,
   writers, prepare/promote, persist/publish e confirmação. Corrigida a
   classificação de falha pós-commit, com teste de confirmação. Contratos
   distintos, IDs/hashes e manifesto canônico conferidos; STEP-2 falha fechado.
2. Source, ownership, unidade e cor: seguido locator→CAF→bridge→escrow→custody,
   cancel/substituição/shutdown e dispose conjunto. Conferidos bounds e ausência
   de escala Dart, normas do adaptador, Canvas e constants por entidade Windows.
   Sem pathname/fallback. Conferida recusa de transitórios aninhados no documento.

Não restam achados críticos, altos ou médios nas fronteiras desta fase.

## Validação

| Validação | Resultado |
| --- | --- |
| STEP e schemas com DLLs Debug | 22 testes passaram |
| STEP e schemas com DLLs Release | 22 testes passaram |
| BREP/STL/runtime/transações/integridade/document writers/staging/custody/CAF/source bridge/viewport | 323 testes passaram |
| OCCT build Debug / Release | Passaram |
| Bridge build Debug / Release | Passaram |
| OCCT CTest Debug / Release | 12/12 por configuração |
| Bridge CTest Debug / Release | 2/2 por configuração |
| CAF CTest Debug / Release | 19 passaram; teste entre volumes ignorado por configuração |
| Windows Release completo, incluindo renderer por entidade | Passou; repetido após alterações finais |
| Smoke STEP C→C com DLLs empacotadas Windows Release | Passou, executável de smoke ao lado das DLLs empacotadas |
| flutter analyze --no-pub | Sem issues |
| dart format e clang-format dos trechos C++ alterados | Conferidos |
| git diff --check | Passou |

O primeiro harness Dart não tinha as dependências da DLL em PATH (erro 126).
Adicionar o diretório de DLLs do build ao ambiente de teste resolveu o carregamento;
nenhum fallback produtivo foi introduzido. Uma expectativa inicial de journal
committed confundia flush com pré-promoção: o teste foi corrigido para exigir
preservação dos três assets já promovidos. Analyze identificou uma regra de braces,
corrigida e repetida. Os builds exibem warnings preexistentes de depreciação OCCT.
