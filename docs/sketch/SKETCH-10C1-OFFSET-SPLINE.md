# SKETCH-10C1 — Offset de Spline Interpolada

## Estado

- Worktree: `C:\flcad_worktrees\sketch-10-offset`
- Branch: `feat/sketch-10a-offset`
- HEAD: `555e7322aa44c060c4e3c7dd158d219588bd80c7`
- Build: Windows Debug experimental concluído
- Avaliação manual: pendente do operador
- Integração produtiva: NO-GO; não autorizada nesta etapa

## Causa funcional

O Offset geométrico introduzido no SKETCH-10A tratava linhas, arcos e círculos, mas não reconhecia `SketchSpline` interpolada. A entidade era encaminhada ao ramo de cadeia de linhas e rejeitada. A avaliação matemática foi ampliada sem tratar uma spline como uma sequência de linhas: o resultado é reconstruído como outra spline centrípeta Catmull–Rom.

## Implementação

1. `SketchSplineGeometry.evaluateSpan` avalia a fórmula de interpolação existente; `derivativesAtSpan` calcula primeira e segunda derivadas por diferenças finitas centrais ou unilaterais.
2. O offset usa a tangente e a normal local em XY. Z é preservado e splines não planares, Bézier, knots degenerados ou tangentes degeneradas são rejeitados.
3. Curvatura assinada é avaliada por `κ = cross(P′, P″) / |P′|³`. Se `1 − dκ ≤ 1e-5`, o raio local é incompatível e a operação é rejeitada.
4. O alvo é subdividido adaptativamente: os desvios em ¼, ½ e ¾ do intervalo são comparados à corda. A tolerância interna de corda é `0,01 mm` (20% da meta de `0,05 mm`).
5. Knots deslocados são reconstruídos como spline interpolada. A distância bidirecional entre polilinhas amostradas guia até 12 refinamentos; se a estimativa passar de `0,05 mm`, se os limites forem excedidos ou se houver interseção, a operação é rejeitada.
6. Limites: 8.192 amostras adaptativas de alvo, profundidade de subdivisão 12, 12 refinamentos e 250.000 visitas da varredura de autointerseção. O último orçamento conta a leitura da lista ativa, a remoção de itens e cada visita antes dos filtros. O preview rejeita com diagnóstico ao excedê-lo.
7. A reconstrução é amostrada a 128 pontos por span durante a estimativa; preview e `sampledPoints` persistido usam 64 por span. O erro exibido é uma estimativa discreta entre polilinhas, não um limite matemático global do erro contínuo.
8. A entidade resultante é independente, preserva a spline original e armazena `sourceEntityIds`, distância assinada, direção e erro estimado. Não é criada constraint associativa.
9. Apply usa a transação canônica; Undo/Redo são atômicos. Save/Open preserva ID, tipo e metadados.

O suporte anterior a `SketchEllipse` também foi preservado como entidade independente: aumentar/reduzir ambos os raios, conforme a regra axis-based existente. Essa operação é uma aproximação, não um offset equidistante exato da elipse.

## Evidência dimensional

Fixture de quatro knots suaves e curvatura variável; referência calculada por amostras independentes da spline original. Resultados da execução direcionada:

| Direção assinada | Knots resultantes | Erro máximo estimado |
|---:|---:|---:|
| `+1,25 mm` | 10 | `0,0384802704 mm` |
| `−1,25 mm` | 12 | `0,0398613154 mm` |

Ambos ficaram abaixo da meta amostrada de `0,05 mm`. O teste também confirma Z preservado, transformação por WCS rotacionado e rejeição de raio local incompatível. Esses valores não garantem o erro máximo contínuo entre as amostras.

## Regressões

| Validação | Resultado |
|---|---|
| `test/sketch_offset_geometry_test.dart` | PASS — 21 testes, incluindo ambas as direções, curvatura variável, referência dimensional, spline bow-tie, budget adversarial, rollback, Undo/Redo, Save/Open, WCS e elipse |
| Widget real `Offset interpolated spline...` | PASS — botão Spline, callbacks de pontos, botão Offset, clique de seleção na viewport, preview, erro visível, Apply desabilitado em conflito, Cancel, Escape, Apply, Undo e Redo |
| `test/sketch_operator_functional_flow_test.dart` | PASS — 35 testes na execução completa; o widget de spline também foi reexecutado isoladamente após o ajuste final |
| `test/g129_1_driving_dimensions_test.dart` | PASS — 25/25, incluindo Driving/Driven e Save/Open |
| `test/sketch_editor_test.dart` | PASS — 11 testes |
| `test/sketch_scene_adapter_visual_resolution_test.dart` | PASS — 6 testes, incluindo amostras de spline |
| `flutter analyze --no-pub` | PASS — exit code 0, sem diagnósticos no estado final |
| Suíte Flutter global | SKIPPED — não executada nesta etapa |
| Native GPU em execução real | SKIPPED — preview usa a geometria `segments` do overlay já suportado; o teste confirma scene preview, não inicialização visual manual do backend nativo |

As rejeições por orçamento e autointerseção deixam a geometria e `undoDepth` invariantes. O widget confirma que falha de curvatura é exposta no painel e que Apply fica desabilitado.

## Revisão independente

Revisão somente leitura atualizada: **GO condicionado para validação experimental**. Os achados sobre spline não reconhecida, autointerseção primeiro/último, elipse e orçamento de trabalho foram tratados e cobertos. A revisão ressalva que a precisão continua amostrada, sem garantia global, e que o orçamento de varredura é aplicado por chamada (alvo e reconstrução separadamente). A revisão independente não executou testes.

## Build experimental

Comando: `flutter build windows --debug --no-pub`
Resultado: PASS, exit code 0; 70,5 s.

- Executável: `build\windows\x64\runner\Debug\flcad_mobile.exe`
- SHA-256 do executável: `6BA03EA304481768BC401222A07480C94C0A421018A5596FF1DF129688E2FE63`
- Snapshot: `build\windows\x64\runner\Debug\data\flutter_assets\kernel_blob.bin`
- SHA-256 do snapshot: `E273F5C0F00F8F8D3B62FF57590E59C7152AB5A9D38429B125E3B9CA715FE235`
- SHA-256 anterior SKETCH-10B: `E8C5B31322BAC4CD959184DD5596C4A20440586449D54890EE3A93E63EF2926B`

O hash do snapshot mudou, portanto o pacote contém um kernel Dart diferente do SKETCH-10B. O hash nativo do executável permaneceu igual ao build anterior; a identidade da alteração Dart é verificada pelo `kernel_blob.bin`.

DLLs junto ao runner Debug:

| DLL | SHA-256 |
|---|---|
| `cad_asset_fs.dll` | `61D2A2349ECB726EAF1EEB5855F3653933FDB201F481D1805EB3992689EFA680` |
| `flcad_opencascade.dll` | `DD1673230E89F954DDF74335097C5F0B7CD309689CF405F35F16362D403FA102` |
| `cad_occ_bridge.dll` | `2E33B6D6E5E56B982698A87F1B4A7E273ECAEBF31790B8EDFD5BD908AE65BD75` |

O build Windows concluiu com essas DLLs no pacote. Não foi executado teste de carregamento dinâmico nem abertura manual do aplicativo nesta etapa.

## Arquivos da etapa

- `lib/core/sketch_engine/geometry/sketch_spline_geometry.dart`
- `lib/core/sketch_editor/geometry/sketch_offset_geometry.dart`
- `lib/core/sketch_editor/engine/sketch_editor_engine.dart`
- `lib/app/engineering_bridge/operational_reverse_engineering_controller.dart`
- `lib/app/desktop/desktop_application.dart`
- `test/sketch_offset_geometry_test.dart`
- `test/sketch_operator_functional_flow_test.dart`

As alterações locais preexistentes do SKETCH-10A/B e registradores Flutter foram preservados. Nenhum commit, push, merge ou release foi feito. As árvores protegidas não foram modificadas.

## Decisão

- **GO** para nova avaliação manual controlada do Windows Debug experimental, em um projeto descartável.
- **NO-GO** para aprovação manual: aguarda teste do operador, incluindo visualização do preview e Cancel.
- **NO-GO** para integração produtiva.

Confirme visualmente a direção positiva/negativa, a forma do offset e o preview no backend de viewport usado pelo operador. Cancel/Escape devem remover o preview; Apply deve criar uma spline independente que sobreviva a Undo/Redo e Save/Open.
