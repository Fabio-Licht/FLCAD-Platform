# STEP-2C — gate de lifecycle do STEP managed

Base: `6807319`, branch `fix/cad-runtime-transaction-coordinator`.

## Matriz curta de fronteiras e evidência

| Fronteira | Evidência existente ou STEP-2C |
| --- | --- |
| Pré-promoção: nada publicado, staging preservado, owners drenados | `failure at managedStep:beforeShapeWrite/beforeDisplayWrite/beforeAppearance/file:chunkWritten/beforePromotion` |
| Pós-promoção, pré-commit: três assets preservados e quarentena | `failure at managedStep:afterPromotion/beforePersistence` |
| Pré-commit versus pós-commit e recovery | `persistence failure preserves prior confirmed owners and asset bytes`; `confirmation failure reports persisted commit and requires recovery` |
| Open: cada asset, hash, manifest e mutação tardia | `open rejects missing/divergent …`; `open rejects appearance …`; `anchored STEP … rejects late mutation` |
| Redo: cada asset, hash e manifest coerente inválido | `STEP Redo asset failures preserve history, scene and prior owners`; `STEP Redo parses a coherent invalid appearance from durable history` |
| Segunda entidade preparada | `STEP open second drains prepared owners deterministically` |
| Cor, nome, unidade, ausência de cor e duas cores | modos reais 0/1/2; `two STEP colors …`; `STEP history keeps first color …` |
| Undo/Redo e assets imutáveis | `STEP Undo removes presentation before disposal and Redo restores assets`; `repeated STEP Undo Redo …` |
| Close: apresentação → retenção → dispose | `STEP close removes presentation before every dispose` |
| Revogação de import/open/Redo | gates `cancel/replace/shutdown` de import, open e Redo |
| Leases, quarentena e cleanup individual | `native_allocation_custody_test`; `post-commit cleanup failure …` BREP, que executam o mesmo `ManagedEntityGeometry.dispose` e custody |
| Compatibilidade e ausência de fallback | teste misto STEP/BREP/STL/legado; regressões BREP/STL; contador `pathImports` zero |
| Dados persistidos sem residência e assets estáveis | modos reais; testes Undo/Redo/open/close com inventory e inspeção de documento/journal |

Os testes BREP/STL e de custody são reutilizados apenas onde exercitam a mesma
função comum, sem ocultar a variante STEP: os testes STEP verificam os três
assets e a aparência; BREP/STL verificam o comportamento de owner/lease e
quarentena que não depende do formato.

## Revisões somente leitura

1. Atomicidade, recovery, schema e aparência: `_prepareManagedOpen` termina
   BREP, mesh, manifest e cena antes de `_persistSnapshot` e
   `_publishManagedOpen`. O commit confirmado não é desfeito por cleanup;
   `_reportCommittedManagedCleanupFailure` marca `recoveryRequired`. A cor
   nasce do manifest validado e só é convertida para sRGB na apresentação.
2. Ownership, revogação, shutdown e fallback: `_install` remove cena/seleção
   antes de remover retenção e `_disposeManagedGeometry`; CAF fecha capabilities
   na limpeza do prepare. Gates de revogação passam por `tx.validate`. STEP não
   entra no caminho de `KernelDisplayMeshPipeline`, `ReadFile(path)`,
   `importStl(path)`, `NativeShapes` ou `DisplayMeshes`.

Não há achado crítico, alto ou médio aberto após a auditoria. O único aumento
de cobertura é o gate de close STEP, adicionado por evidência direta da ordem
de apresentação e dispose.

## Validação executada

| Gate | Resultado |
| --- | --- |
| STEP runtime e schema, DLLs Debug | 55 testes passaram |
| BREP/STL/runtime/transações/staging/custody/CAF/source bridge/viewport | 323 testes passaram |
| flutter analyze --no-pub | Sem issues |
| dart format | Sem diferenças pendentes |
| git diff --check | Passou |

Não houve alteração nativa; portanto não foi necessário build nativo adicional.

## Limites preservados

Não há edição STEP, comando visual, assemblies, cor por corpo/face,
transparência, GC, 2B2B, ABI nova, fallback por pathname ou gate final STEP.
