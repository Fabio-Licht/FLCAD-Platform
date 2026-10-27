# SKETCH-09E — Estabilização do Sketch integrado

Data: 2026-10-27. Ambiente: Flutter 3.44.9, Dart 3.12.2, Windows.

Worktree: `C:\flcad_worktrees\sketch-09-integration`, branch `integration/sketch-professional-09`. Não houve commit, push, merge, PR nem release. Nenhuma escrita foi feita em `C:\flcad_mobile`, na árvore isolada do Sketch 08, nem no worktree G001.

## 1. Causa e correções

O `execute` dos comandos de sessão já capturava checkpoint. O `undo` e o `redo` não capturavam. Um `redo` que mutava o domínio e lançava exceção antes de ser aplicado restaurava só as pilhas do `CommandManager` e deixava a mutação no domínio.

`CommandManager` agora captura o checkpoint registrado antes de `execute`, `undo` e `redo`. Se a operação lança exceção antes de ser aplicada e o checkpoint existe, o snapshot é restaurado e o erro original segue. Se não existe checkpoint, as pilhas do gerenciador são restauradas, o erro original segue, e `lastUncheckpointedFailure` registra `CommandUncheckpointedFailure`. Isso não afirma que o domínio voltou ao estado anterior. Um sucesso posterior não apaga essa marca. Rejeição de validador ocorre antes da captura e não marca a falha.

Não foi criado rollback genérico de memória nativa. `CadDocument.detachedCheckpoint` continua copiando mapas e listas e compartilhando `ShapeHandle` e mesh. `ShapeHandle.metadata` é imutável, então escrita in-place é rejeitada pelo próprio handle. O objeto nativo endereçado por `kernelId` não é copiado nem restaurado por esse snapshot.

O Explorer deixou de trocar qualquer entidade sem nome útil por `Geometria`. Nome gravado é preservado, inclusive UUID em entidade que não é sketch. `Geometria` só aparece na apresentação de sketch (`kind` sketch, `parentSketchId` ou `sketchEntity`) quando o nome está vazio ou contém UUID. Nos demais casos o fallback é `entity.id`.

O teste de distância sobre referência gerenciada clicava a extremidade original `(30, 5)`. A coincidência translada a linha alvo inteira e preserva o comprimento: a extremidade passa a `(20, 0)` e a âncora permanece `(0, 0)–(10, 0)`. O clique foi atualizado para a extremidade resultante. O comportamento do solver não foi alterado.

## 2. Cobertura dos checkpoints

| Caminho | Checkpoint | Falha antes de aplicar |
| --- | --- | --- |
| Comandos de sessão em `operational_reverse_engineering_controller.dart` | Um closure compartilhado: sketch, constraints, editor e `CadRuntime` (documento, pilhas undo/redo, revisão, `recoveryRequired`) | Restaura o snapshot. `execute`, `undo` e `redo` capturam o mesmo closure |
| `project.new`, `project.open`, `project.save`, `project.close`, `import.*`, `export.*` e workspace em `desktop_command_coordinator.dart` | Nenhum | Não há rollback de arquivo, arquivo de projeto ou importação de kernel. A falha fica visível em `lastUncheckpointedFailure` |
| Depois que a operação já foi aplicada | Não usa o snapshot | Usa o comando inverso. Se o inverso também falha, `CommandRecoveryFailure` |

O snapshot documental não promete restaurar arquivo de projeto, importação externa nem geometria nativa OCCT. Transações nativas de kernel continuam no caminho que já existia.

## 3. Testes

A suíte sequencial (`--concurrency=1`) não é PASS: **460 PASS, 1 FAIL**. A falha foi `panel_view_model_label_test`, que lia a linha pelo nome da chave do mapa em vez do id da entidade. O rótulo do sólido sem nome já era `solid-1`. O teste foi corrigido e reexecutado: **1 PASS**.

O journal não entrou nessa suíte. Foi executado sozinho, para não repetir o timeout de 30 s sob carga: **3 PASS**, exit 0, cerca de 7 s, inclusive `real coordinator startup repairs a partial journal in another process`.

| Verificação | Resultado |
| --- | --- |
| Suíte sequencial (sketch, G124, G126, G129, CommandManager, persistência, viewport, picking, latência, WCS, Adaptive Workspace, referência gerenciada, STL) | 460 PASS, 1 FAIL (teste de rótulo; reexecução 1 PASS) |
| `command_manager_atomic_rollback_test` na reexecução, incluindo redo, validador e marca persistente | 8 PASS |
| Journal, segregado | 3 PASS |
| `sketch_on_managed_reference_test` com `flcad_occ_step_bridge_smoke.exe` real | 19 PASS |
| `cad_runtime_managed_stl_test` com `cad_occ_bridge_smoke.exe` real | 29 PASS |
| `flutter analyze --no-pub` | PASS, No issues found, 174,6 s |
| OCCT real com a DLL do aplicativo | 4 PASS, exit 0, nenhum skip |

Os seis erros da rodada anterior:

| Erro anterior | Nesta rodada |
| --- | --- |
| `sketch_on_managed_reference_test` não carregava | 19 PASS, fixture STEP real |
| `cad_runtime_managed_stl_test` não carregava | 29 PASS, fixture nativo real |
| Journal com timeout de 30 s | 3 PASS, execução isolada |
| Fix depois de Redo vazio | PASS dentro da suíte sequencial |
| Dois casos G124 com timestamp novo depois do rollback | PASS dentro da suíte sequencial |

Fixtures reais, sem dados inventados:

- STEP: `build\windows\x64\opencascade\Debug\flcad_occ_step_bridge_smoke.exe`, SHA-256 `D9849CA78F8541287E99A4393567A1D4417239F32A25C183FEAACDE06F0E45F6`.
- STL: `build\cad_occ_bridge_tests\Debug\cad_occ_bridge_smoke.exe`, SHA-256 `BAF8E5C40E65E712A1C1C298F4B2D33321D63A7B22F4C47A771AC60A01EE4B8F`, compilado do `tests/smoke.cpp` do worktree.
- O STL exige `flcad_occ_test_path_import_count`. A DLL do aplicativo não exporta esse contador. Foi usada uma DLL de teste, build separado com `FLCAD_OCC_PATH_AUDIT=ON`, SHA-256 `F1203820CAC285E361F1A1299A110EA0342DF38957761A6F1D182E8FCF5759CE`. Ela não substitui a DLL do executável.

OCCT da avaliação usou a DLL do aplicativo `7160510D310C132B3A07F0E6007B4DDCB78806658565DEFC734C46EFF38F2C05` e o PATH de `build\windows\x64\runner\Debug`.

## 4. Riscos residuais

- Comandos de projeto, importação, exportação e workspace podem deixar efeito parcial. A falha fica visível e não é apresentada como rollback.
- Handles de shape e mesh continuam compartilhados. Memória nativa do kernel não entra no checkpoint.
- O journal passou sozinho. Não foi repetido dentro da suíte de 460 testes.
- A revisão independente leu o código antes da correção do comentário de `CommandCheckpoint` e antes do acerto da chave do teste de rótulo. Os dois ajustes não mudam o comportamento que a revisão aprovou.

## 5. Parecer independente

[Revisão SKETCH-09E](b1d1e68c-cdde-43d0-b3f8-ab3343ea0170), leitura exclusiva, sem executar testes. **GO** para avaliação manual deste worktree. **NO-GO** para merge produtivo, porque não há autorização. Nenhum defeito de comportamento foi demonstrado. O comentário que ainda descrevia só o `execute` foi atualizado depois do parecer.

## 6. Build

`flutter build windows --debug` exit 0, 67,0 s. O runner nativo não foi religado: as fontes nativas não mudaram.

| Artefato | Caminho | Bytes | Escrita | SHA-256 |
| --- | --- | --- | --- | --- |
| Executável | `build\windows\x64\runner\Debug\flcad_mobile.exe` | 1807872 | 2026-10-27 11:44:30 −03:00 | `91EE59400F29AD7189A0DDDAF2CBE76828BC1916EF61447827B52CE8323D6F67` |
| Snapshot Dart carregado pelo Debug | `build\windows\x64\runner\Debug\data\flutter_assets\kernel_blob.bin` | 84063768 | 2026-10-27 12:34:41 −03:00 | `4AD688B5196BFD0EE8189090DA78129510465509AFD94AEDAD0E163C3B922647` |
| DLL OCCT do aplicativo | `build\windows\x64\runner\Debug\flcad_opencascade.dll` | 1954304 | 2026-10-27 11:44:31 −03:00 | `7160510D310C132B3A07F0E6007B4DDCB78806658565DEFC734C46EFF38F2C05` |

## 7. Proteções

- Principal: branch `feat/plane-axis-intersection-point`. Porcelain igual ao conjunto já sujo antes desta etapa (viewport, controller, seed, host nativo, diagnósticos de latência, `artifacts/` e screenshots).
- Solver isolado: SHA-256 `870B0FA6596DAAED361409F2FFBF32902FF5235C3554AF27E3539469B3B82D70`.
- G001: branch `feat/ai-agent-g001-foundation`. Porcelain limitado aos sete gerados de plugin já existentes. Nenhuma fonte de sketch foi escrita lá.

## 8. Decisão

- Avaliação manual deste worktree: **GO**, com os riscos da seção 4. O executável Debug carrega o snapshot Dart das 12:34.
- Integração produtiva em `C:\flcad_mobile`: **NO-GO**. Merge não foi autorizado, e o parecer independente também é NO-GO.
