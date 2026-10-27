# SKETCH-09 — Integração controlada do Sketch Professional 08

Data: 2026-10-27. Ambiente: Flutter 3.44.9, Dart 3.12.2, Windows.

Nenhuma escrita foi feita em `C:\flcad_mobile`, na árvore isolada do Sketch 08, nem no worktree G001. Não houve commit, push, merge, PR nem release.

## 1. Estados e hashes das origens

| Origem | Estado verificado ao final |
| --- | --- |
| Principal `C:\flcad_mobile` | branch `feat/plane-axis-intersection-point`, HEAD `81e70d832e0c69ac25b6224f1ebcd4cef8fbfe54` |
| Sketch 08 isolado | `C:\Users\fabio\AppData\Local\FLCAD\automation-bridge-runtime\sketch-professional-08-functional-isolated`, sem Git |
| Solver isolado | SHA-256 `870B0FA6596DAAED361409F2FFBF32902FF5235C3554AF27E3539469B3B82D70`, igual ao da consolidação |
| `pubspec.lock` principal | `CCCB10EA438DE1E67C28DF289214C4450904D9CAB1CAB9984C11AB275F206C30` |
| `pubspec.lock` isolado | `584CBC0FF8A64B88F7F4B719EE266E341D69C5FFB0F290AF22B20AC1FB7D2612` |

O `pubspec.lock` do worktree permanece igual ao do principal. O lock isolado não foi copiado.

Porcelain do principal, inalterado:

- `M lib/app/cad_viewport/native/integrated_native_viewport_widget.dart` `23A37BFB06B14ECFB76899CFA1EF89024A8D59BD6A6231D4895E26980BF8AFF1`
- `M lib/app/cad_viewport/native/native_viewport_bridge.dart` `780BCB639F813EB1E609F7C75AE3B7D508F17753F6C34177129D943E6E16A93A`
- `M lib/app/engineering_bridge/operational_reverse_engineering_controller.dart` `B99D4BA4AA53F6E37DFE09CB76CB383999A26F7B43099F7D84CFA529D28ADA87`
- `M test/er_p2c_c4_f1_real_seed_matrix_test.dart` `D982CC6D2F0EC350D1AAB9C170E55D897D8D4D76318C51E82318D0F58716D8FC`
- `M windows/runner/native_viewport_host.cpp` `AA3F493A89C9CAEB16A1B479B75B7BD92B73AAA5EA72B4B2DE362BA635D65DC4`
- `M windows/runner/native_viewport_host.h` `47F54251FC7599F1D486DB5FA1343E09E05EFF9B33C54D4FE92273AF335D7BC2`
- `?? lib/app/cad_viewport/selection_latency_diagnostics.dart` `4CF5D53BAFFA4ECD56490382FAB8CC4C4A63ACB5E4E5F9756583FA97279E2744`
- `?? test/selection_latency_diagnostics_test.dart` `043825509E8B5936A0F2F41A721109A358FA36839049333DC38D30FF3AE69419`
- `?? artifacts/` e `?? test_assets/screenshots/`

## 2. Evidência da preservação

Preservação fora das duas origens: `C:\flcad_worktrees\sketch-09-preservation`.

- Fontes paralelas pequenas e screenshots copiados com hashes conferidos na criação.
- `artifacts/` (5897 arquivos, cerca de 13,9 GB) ficou no principal e foi inventariado no lugar. Não foi duplicado.
- Os oito hashes acima foram relidos no principal depois da integração e continuam iguais.
- O worktree não herda arquivos não rastreados. Os arquivos de viewport, host nativo, latência e o teste de seed foram copiados da preservação para o worktree.
- O controller integrado é o do Sketch 08, que já contém `SelectionLatencyDiagnostics`, mais o checkpoint de sessão acrescentado só no worktree.

## 3. Branch, worktree e SHA base

- Worktree: `C:\flcad_worktrees\sketch-09-integration`
- Branch: `integration/sketch-professional-09`
- SHA base: `81e70d832e0c69ac25b6224f1ebcd4cef8fbfe54`
- A branch do principal permaneceu `feat/plane-axis-intersection-point`.
- O worktree G001 permaneceu em `feat/ai-agent-g001-foundation`. Esta sessão não escreveu nele.

## 4. Arquivos integrados e conflitos resolvidos

Cópia seletiva a partir do isolado, mais os arquivos paralelos da preservação. `pubspec.lock`, `build/` e `.dart_tool/` do isolado não foram copiados.

Fatias de código: núcleo do Sketch, solver, constraints, editor, repositório CAD, CommandManager, coordenador, runtime, controller, picking, desktop, painel de superfície, view model de painel e os testes correspondentes.

Ajustes feitos só no worktree:

- `CommandCheckpoint` em `lib/app/commands/command_registry.dart`.
- Restauração em `CommandManager._execute` quando `execute` lança antes de `applied`.
- Checkpoint de documento em `CadRuntime` (`captureCommandCheckpoint` / `restoreCommandCheckpoint`), com cópia estrutural que compartilha handles de shape e mesh.
- Os comandos de sessão `SketchSurface` capturam Sketch, constraints, editor e documento antes de executar.
- `SketchEntity.fromJson` passa a restaurar `owner` e `timestamp`.

Conflitos tratados:

- Controller: a faixa de latência do principal está presente no controller isolado. O arquivo do principal não foi sobrescrito.
- `pubspec.lock`: mantido o do HEAD.
- `desktop_application.dart` e `panel_view_model.dart` vieram do isolado porque estavam limpos no principal. O rótulo `Geometria` do Explorer é global para entidades sem nome ou com nome UUID.
- A regra de 0,75 px do picking é do picker compartilhado, não só do Sketch.

Diff do worktree contra o SHA base: 43 arquivos rastreados, +9403 / −2109, além de arquivos novos não rastreados. Não há commit.

## 5. Fatias

| Fatia | Estado |
| --- | --- |
| 1. Núcleo, solver, módulos exclusivos e testes | Concluída. `sketch_delete_lifecycle_test` passou depois do controller. |
| 2. CommandManager, persistência, Save/Open, Undo/Redo | Concluída no worktree. |
| 3. Controller, latência e picking | Concluída. Latência e viewport paralelo entraram a partir da preservação. |
| 4. Desktop, Adaptive Workspace, propriedades, Fillet, Chamfer, Trim, Extend | Concluída no worktree. |

Nenhuma fatia ficou pendente de cópia. A avaliação manual ainda é necessária.

## 6. Integridade do CommandManager

O buraco original foi reproduzido e fechado para comandos que fornecem checkpoint.

- `test/command_manager_atomic_rollback_test.dart`: 4 PASS.
- Uma mutação seguida de exceção, com checkpoint, restaura documento, geometria, constraints, IDs, histórico, Undo/Redo, dirty, revisão e previews do domínio de teste. O teste do runtime restaura o `CadDocument`, a revisão e o `ShapeHandle` compartilhado.
- O mesmo teste demonstra que um comando sem checkpoint continua deixando a mutação. Esse buraco permanece para comandos que não registram checkpoint.
- O redo não captura checkpoint. Uma falha de redo antes de `applied` não usa essa restauração.
- A cópia do documento compartilha handles de shape e mesh. Mutação interna desses handles não é desfeita.
- Os comandos de sessão do Sketch registram checkpoint. O caminho `execute` desses comandos restaura Sketch, constraints, editor e o snapshot documental.

## 7. Resultados

Suíte ampla no worktree, `flutter test --no-pub`, exit 1 na primeira passagem completa: **409 PASS, 6 FAIL**.

Reexecução isolada depois da correção de `timestamp`/`owner` em `SketchEntity.fromJson`: **4 PASS, exit 0**.

| Verificação | Resultado |
| --- | --- |
| Solver, paramétrico, editor, retângulo, autoridade canônica, DOF, rascunho de cota, revisão | PASS na suíte (sem `[E]`) |
| `sketch_delete_lifecycle_test` | PASS na suíte |
| Persistência, recuperação de processo do repositório, journal, transação de runtime, comandos profissionais | PASS na suíte, com uma ressalva |
| Journal `real coordinator startup repairs a partial journal` | FAIL por timeout de 30 s na suíte paralela; PASS na reexecução isolada |
| `selection_latency_diagnostics_test` | PASS na suíte |
| Picking de reconstrução e viewport profissional | PASS na suíte |
| G124 funcional | 2 FAIL na suíte (timestamp após rollback); os dois casos PASS na reexecução |
| G126, G129 | PASS na suíte |
| Fluxo do operador | 1 FAIL na suíte (Fix após redo); PASS na reexecução |
| `sketch_on_managed_reference_test` | Não executado. O `main` exige DLLs e fixture ausentes no ambiente e aborta no `!`. |
| `cad_runtime_managed_stl_test` | Não executado, pelo mesmo motivo. |
| Alinhamento WCS (`alignment_coordinate_system_test`) | PASS na suíte |
| Painéis destacáveis, layout e extração de painéis Sketch | PASS na suíte |
| OCCT com DLL aprovada `CD31EDD25A45BCCCEEED076506A69D03BCA09B53388AF78AF7D0366D31DCBEF5` e PATH do Debug isolado | 1 + 3 PASS, exit 0, nenhum skip |
| OCCT com a DLL do exe integrado `7160510D310C132B3A07F0E6007B4DDCB78806658565DEFC734C46EFF38F2C05` e PATH do Debug do worktree | 1 + 3 PASS, exit 0, nenhum skip |
| `flutter analyze --no-pub` | PASS, No issues found, 93,7 s |
| `flutter build windows --debug` | PASS, 126,9 s |

Os dois hashes de DLL diferem porque o Debug do worktree foi recompilado. O Git não mostra diff de conteúdo nas fontes nativas contra o SHA base. As duas DLLs passaram os mesmos quatro testes.

## 8. Revisão independente

Revisão local somente leitura, modelo GPT-5.6 Sol, conversa [Revisão SKETCH-09](0ded912b-ce34-41c6-b5fc-c2e74c4ec501). Nenhum arquivo foi alterado por ela.

Conclusão do revisor:

- Rollback do `execute` com checkpoint cobre geometria, IDs, histórico, Undo/Redo do Sketch, constraints, previews do editor, documento, revisão, Undo/Redo documental e pilhas do manager.
- Permanecem sem essa proteção: comandos sem checkpoint, o caminho de redo e a mutação interna de handles compartilhados.
- `SketchEntity.fromJson` agora preserva autor e timestamp também em carga normal, não só no rollback.
- A latência paralela está no controller, no widget nativo, na ponte e no host.
- `PanelViewModel._label` transforma qualquer entidade sem nome ou com nome UUID em `Geometria` no Explorer destacado.
- A regra de 0,75 px vale para o picker compartilhado de viewport.
- Avaliação manual: GO com cautela.
- Merge produtivo: NO-GO.

## 9. Executável integrado

`C:\flcad_worktrees\sketch-09-integration\build\windows\x64\runner\Debug\flcad_mobile.exe`

Tamanho 1.807.872 bytes. Escrito em 2026-10-27 11:44:30 −03:00. A DLL OCCT ao lado desse executável é a de hash `7160510D…F2C05`, exercida pelos quatro testes OCCT acima.

## 10. GO / NO-GO para avaliação manual

**GO**, neste worktree, com a cautela da revisão.

O Sketch aprovado, o rollback dos comandos de sessão, a análise, o Debug e o OCCT real desse Debug estão verdes. A avaliação manual deve olhar Fillet, Chamfer, Trim, Extend, Undo/Redo, o Explorer (`Geometria`) e o picking de 0,75 px.

## 11. GO / NO-GO para integração produtiva

**NO-GO.**

Esta fase não autoriza merge em `C:\flcad_mobile`. Além disso permanecem: comandos sem checkpoint, redo sem o mesmo rollback, handles compartilhados, `sketch_on_managed_reference_test` e `cad_runtime_managed_stl_test` não executados, e o rótulo global do Explorer.

Menor próximo passo, quando houver autorização nova: executar os dois testes de referência gerenciada e STL com as DLLs e o fixture presentes, e decidir se o rótulo `Geometria` fica restrito ao Sketch antes de qualquer merge.
