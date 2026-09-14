# STEP-2A — reabertura managed com aparência durável

Base: `668bdea`, branch `fix/cad-runtime-transaction-coordinator`.
Escopo: save/close/open; Undo/Redo STEP continua recusado explicitamente.

## Contrato e implementação

`CadRuntime.open` reutiliza `_prepareManagedOpen` e `_publishManagedOpen` de
BREP/STL. STEP é identificado por `managedStepAssets`, validado pelo decoder
documental estrito e por `ManagedStepAssets`; não é tratado como BREP direto.
Não se adquire outra transação dentro da fila.

Cada entidade resolve três referências distintas: BREP, STL de exibição e
appearance manifest. `_AssetPaths.openManagedAsset` confere schema do descriptor,
projeto, ID, inventory exato, ausência de reparse, identidade CAF, tamanho e
SHA-256. Os objetos de payload e descriptor permanecem abertos e são
revalidados antes da transferência de custody/publicação.

BREP e STL são restaurados por source bridge C→C, sem bytes CAD em Dart nem
reimportação STEP. Os resultados entram imediatamente no escrow/custody
existente. O BREP deve ser um solid válido; a mesh é validada pelo adaptador
quanto a índices, contagens, finitude e bounds. O descriptor v1 da shape não
contém bounds geométricos úteis: não se afirma comparação BREP/mesh por bbox.
A coerência durável está no conjunto de IDs/hashes, geometria válida,
unidades canônicas e nome consistente com o manifest.

`readBoundedMetadata` lê somente o pequeno manifest usando `CAF.read` no objeto
já admitido e um pin de source, com limite de 16 KiB aplicado antes do digest
do payload. Confere identidade/hash antes e depois da leitura e SHA-256 dos
bytes efetivamente lidos. Não usa `File.readAsBytes`, pathname de descriptor ou
reabertura por locator. A resolução relativa confinada continua sendo a do CAF.

A leitura usa UTF-8 estrito e JSON objeto. `StepAppearanceManifest.fromJson`
valida os onze campos exatos, schema `flcad.step-appearance`, versão inteira 1,
nome UTF-8 limitado, unidade declarada/escala positiva finita, resolução mm
com escala 0.001, RGB linear-sRGB finito em [0,1], alpha opaco ou ausência
explícita. Os bytes devem corresponder à serialização canônica já produzida
por STEP-1A1; isso rejeita chaves duplicadas e outras representações ambíguas.
O nome deve corresponder ao documento. A escala declarada é proveniência:
nenhuma escala adicional é aplicada ao BREP ou à mesh na reabertura.

A cena recebe `rootLinearRgb` antes da publicação. Canvas e mensagem Windows
reutilizam `cadRootColor`/`cadRootSrgb`, com conversão linear→sRGB somente na
apresentação. Cada mensagem possui a própria cor por ID. Sem cor, nenhum campo
de cor é criado e o fallback local continua sem modificar o manifest.
Não foi necessário alterar renderer, ABI ou C++ produtivo.

Todas as entidades, cena e assets são preparados antes de instalar documento,
histórico, seleção e retenções. A notificação ocorre depois da instalação
completa. Falha de qualquer preparação descarta somente owners pendentes e
mantém o documento anterior. `open` aceita cancelamento opcional; cancelamento,
abertura substituta e shutdown revogam a transação, e cada fronteira valida
essa revogação antes de continuar. A rotina comum fecha capabilities e drena
owners/leases. Close remove cena e retenções antes de dispose e não escreve
nos assets.

## Matriz de evidência

| Garantia | Testes em `cad_runtime_managed_step_test.dart` |
| --- | --- |
| Import/save/close/open, IDs, hashes, nome, unidades, cor | modos reais 0/1/2 |
| Ausência explícita de cor, sem campo visual persistido | modo 1 |
| Duas cores independentes, mensagens por ID, publicação completa, ciclos | two STEP colors survive repeated atomic open and close |
| STEP + BREP + STL + legado serializado | mixed STEP BREP STL and serialized legacy reopen together |
| Cada payload ausente ou hash divergente, documento anterior preservado | open rejects missing/divergent brep/display/appearance |
| JSON truncado/inválido, UTF-8, schema/versão, RGB, unidade, nome, duplicatas, limite | open rejects appearance … after hash verification |
| Segunda entidade falha após primeira preparada | STEP open second drains prepared owners deterministically |
| Cancelamento, substituição e shutdown sem publicação parcial | STEP open cancel/replace/shutdown drains prepared owners deterministically |
| Capabilities liberadas | rename-probe após erros de manifest e revogação |
| Mutação tardia impedida e hashes/tamanhos intactos | anchored STEP brep/display/appearance rejects late mutation |
| Close retira cena/retenções/apresentação antes do dispose; assets estáveis | teste de ciclos e comparação de inventory CAD |
| Sem caminho legado | contador nativo de pathname import zero; ausência de NativeShapes/DisplayMeshes |

Os testes anteriores de STEP-1A1 permanecem cobrindo import, staging,
persistência, recuperação e falhas pós-commit. A suíte de 323 regressões cobre
BREP, STL, runtime, transações, integridade referencial, document writers,
staging, custody, CAF, source bridge e viewport. Não há duplicação de sua
instrumentação de leases/dispose individual.

## Revisões somente leitura

1. Atomicidade/schema/manifest/cor: seguidos decoder, resolução CAF, preparação
   dos três assets, revalidação e instalação síncrona comum. Conferida a
   associação por entidade e a ausência de conversão/escala dupla. Nenhuma
   abertura STEP chega ao `KernelDisplayMeshPipeline`; o comportamento legado
   existente permanece disponível para entidades legadas. A fixture mista usa
   ponto serializado, sem pathname. Não há achado crítico, alto ou médio aberto.
2. Ownership/capabilities/revogação/shutdown: seguidos pins de metadata,
   source bridge, custody imediata, escrow pendente, transferências, cleanup
   comum e close. `tx.finish` completa a revogação e encerra o observador de
   cancelamento; cancelamento tardio não desfaz publicação confirmada. Handles
   CAF deny-write permanecem vivos até o gate de publicação. Nenhum fallback,
   reaquisição da fila ou asset apagado foi introduzido. Não há achado crítico,
   alto ou médio aberto.

## Limites preservados

Undo/Redo STEP, edição documental com STEP, comandos visuais, assemblies,
referências externas, cores por corpo/face, transparência, texturas/PBR/PMI,
GC e 2B2B permanecem fora desta etapa. Cancelamento nativo é cooperativo;
não se adiciona sandbox rígido de CPU/memória. Não há fallback por pathname,
conversão STEP→STL substituindo BREP, mudança de ABI ou limpeza destrutiva.
As alterações C++ são somente fixtures de teste com uma segunda cor.

## Validação executada

| Gate | Resultado |
| --- | --- |
| STEP runtime + schemas, DLLs Debug | 46 testes passaram |
| STEP runtime + schemas, DLLs Release | 46 testes passaram |
| Suíte BREP/STL/runtime/transações/staging/custody/CAF/source bridge/viewport | 323 testes passaram |
| Builds das fixtures STEP bridge/source, Debug e Release | Passaram |
| CTest STEP source C ABI/source/bridge, Debug e Release | 3/3 por configuração |
| flutter analyze --no-pub | Sem issues |
| dart format e clang-format das fixtures | Sem diferenças |
| git diff --check | Passou |

Nenhuma DLL produtiva exigiu alteração; os builds nativos foram necessários
para gerar a segunda cor na fixture. Não foi executado build Windows completo
ou teste visual de pixels/GPU: a reaplicação foi conferida na cena, no helper
Canvas e nas mensagens do renderer, com regressões do viewport existente.

Durante a preparação dos testes, a expectativa de payload ausente foi ajustada
para o erro específico de inventory CAF. A fixture mista exige uma pasta direta
em temp com prefixo `cob-dart-`; também foi corrigida a contagem para conferir os
quatro IDs de geometria, separadamente das coleções profissionais existentes.
Os testes afetados foram repetidos em ambas as configurações. Analyze apontou
braces, corrigidos antes da validação final. Não restou defeito produtivo
crítico, alto ou médio comprovado pelas revisões.

## Arquivos alterados

- `lib/app/runtime/cad_runtime.dart`: cancelamento opcional de open.
- `lib/app/runtime/cad_runtime_transactions.dart`: preparação/restauração STEP.
- `lib/app/runtime/cad_asset_storage.dart`: leitura CAF de metadata limitada.
- `lib/app/runtime/cad_asset_fs_native.dart`: comentário do escopo de source.
- `test/cad_runtime_managed_step_test.dart`: gates STEP-2A e import existente.
- `native/opencascade/tests/step_fixture.h`: segunda cor de fixture.
- `native/opencascade/tests/step_bridge_smoke.cpp`: geração da fixture adicional.
- `docs/engineering/step-managed-open-lifecycle.md`: contrato, matriz e revisões.
- `docs/engineering/step-managed-transactional-import.md`: referência à STEP-2A.
