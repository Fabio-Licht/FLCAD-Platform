# STEP-2B — Undo e Redo de STEP managed

Base: `9204fe5`, branch `fix/cad-runtime-transaction-coordinator`.

STEP entra na mesma transação de histórico usada por BREP-2B e STL-2B, sem
reabrir a fila. A transação prepara todos os recursos necessários antes do
snapshot documental/histórico e da publicação. A instalação reconcilia
documento, cena, seleção e retenção em uma seção síncrona; só depois descarta
as geometrias substituídas.

## Regras STEP no histórico

Uma entidade STEP é sempre o contrato `managedStepAssets` v1: BREP, display
STL e appearance manifest com IDs e hashes independentes. A transição impede
que uma entidade conservada troque seus refs duráveis. Undo pode removê-la do
candidato; Redo que a reintroduz prepara os três assets exclusivamente por
CAF e pelas bridges C→C já aprovadas.

Redo usa `_prepareManagedOpen` para abrir e revalidar BREP, mesh e manifest.
O manifest é limitado a 16 KiB, UTF-8/JSON estrito, schema/versão/canonicalidade,
nome, unidade e RGB linear opaco. O resultado produz `rootLinearRgb`; Canvas e
host convertem para sRGB somente na apresentação. Não há STEP de origem,
pathname ou bloco CAD em Dart.

Uma entidade STEP que não mudou entre os dois snapshots conserva o par native
já confirmado e sua cena, incluindo a cor. Isso evita recriar a primeira
entidade ao desfazer/refazer somente a última. A entidade restaurada continua
passando pela validação integral dos três assets. Não se sintetiza shape nem
se chama o pipeline legado para STEP.

No Undo, `_publishManagedOpen` instala o candidato sem a entidade, remove a
cena/apresentação, reconcilia a seleção e substitui a retenção. A limpeza dos
owners removidos ocorre depois desse limite visual. Assets e descriptors não
são apagados, movidos nem escritos.

`redoDocument` aceita `CadAssetCancellation` opcional. Cancelamento explícito,
nova operação e shutdown revogam a transação; gates após prepare detectam a
revogação e o cleanup comum fecha capabilities, leases e owners pendentes.
Cancelamento após um commit não o desfaz.

## Matriz de evidência

| Garantia | Teste STEP |
| --- | --- |
| Ordem de Undo, seleção, owners e assets imutáveis | `STEP Undo removes presentation before disposal and Redo restores assets` |
| IDs/hashes, nome, unidade e cor restaurados | mesmo teste; manifest e sRGB comparados |
| Ciclos e save/close/open sem duplicação | `repeated STEP Undo Redo has no duplicate owners and reopens` |
| Duas cores: conserva primeira, restaura última | `STEP history keeps first color while restoring only the last entity` |
| BREP/STL/legado mistos | `mixed STEP BREP STL and serialized legacy reopen together` |
| Ausência/hash de cada BREP/STL/manifest | `STEP Redo asset failures preserve history, scene and prior owners` |
| Manifest inválido coerente com histórico | `STEP Redo parses a coherent invalid appearance from durable history` |
| Cancelamento, substituição e shutdown de Redo | `STEP cancel/replace/shutdown revokes a suspended Redo without publication` |
| Sem caminho legado | contador nativo de path import igual a zero em todos os gates |

As falhas de parsing de aparência de open STEP-2A continuam executadas; elas
cobrem JSON truncado/inválido, UTF-8, schema, versão, RGB, unidade, nome,
duplicatas e limite antes de qualquer publicação.

## Revisões somente leitura

1. Atomicidade: `_commitManagedSnapshot` prepara as restaurações, monta a cena,
   faz checkpoint e persiste documento/histórico antes de `_publishManagedOpen`.
   Qualquer falha de Redo preserva os snapshots, cena, seleção e owners atuais.
   Undo instala a retirada antes de `_disposeManagedGeometry`. A cor de STEP
   restaurado só entra na cena preparada; entidade STEP retida usa sua cena já
   confirmada e não mistura cores.
2. Ownership e autoridade: BREP/STL usam objetos CAF já admitidos e bridge C→C;
   manifest usa capability CAF limitada. O cleanup de prepare fecha paths e
   descarta cada owner mesmo quando outro dispose falha. Não há reaquisição de
   fila, fallback por pathname, `importStl(path)`, `ReadFile(path)`,
   `KernelDisplayMeshPipeline`, `NativeShapes` ou `DisplayMeshes` para STEP.

Não foram encontrados defeitos críticos, altos ou médios.

## Limites preservados

Esta fase não adiciona edição STEP, assemblies, referências externas, cor por
corpo/face, transparência, menus/comandos visuais, GC, 2B2B, ABI nova ou gate
final STEP. A validação de shape do descriptor v1 continua limitada ao tipo
`solid`; bounds/índices/finitude efetivos são validados pela mesh preparada.
