# ER-P2C-C2 — contrato futuro do editor universal de parâmetros reconhecidos

Este documento prepara a integração futura de correções paramétricas sem
alterar o reconhecedor, a seleção, a persistência ou a criação CAD.

## Separação de responsabilidades

`MeasuredRecognitionParameters` contém somente o resultado produzido pelo
fitter sobre a seleção original: tipo, origem, eixo/normal, raio ou distância,
estatísticas de resíduos, cobertura, confiança, pontos e fingerprint da malha.

`NominalRecognitionParameters` contém valores escolhidos pelo operador, como
diâmetro alvo, eixo de alinhamento e offset. Esses valores nunca são usados
como entrada obrigatória do fitting ou do crescimento de região.

`RecognitionCoordinateFrame` identifica o sistema de cada vetor: global da
malha, local da entidade ou WCS. A conversão deve ser explícita e reversível;
nenhum alinhamento deve substituir silenciosamente o eixo medido.

`RecognitionCorrectionProposal` relaciona medido, nominal, transformação
proposta, desvios recalculados contra a seleção original, critérios de validade
e proveniência. A proposta é somente dados de preview até confirmação.

`RecognitionCorrectionPreview` é um overlay transitório. Ele pode mostrar,
por exemplo, Ø17,798 → Ø18,000 ou um plano alinhado ao XY, mas não cria uma
entidade CAD, não altera a malha importada e não entra no histórico global.

`RecognitionConfirmation` registra operador, timestamp, seleção/fingerprint,
parâmetros medidos, parâmetros nominais, transformação aplicada e resultado de
validação. A persistência e a criação CAD ficam fora do escopo desta ER.

## Fluxo futuro

1. Congelar a seleção original e sua proveniência.
2. Exibir parâmetros medidos sem reexecutar o fitting.
3. Aceitar parâmetros nominais opcionais e uma transformação no frame escolhido.
4. Recalcular desvios contra os pontos da seleção original.
5. Exibir preview e diagnóstico de validade.
6. Exigir confirmação explícita antes de qualquer operação CAD/persistente.

## Pontos de integração preservados nesta ER

- `RecognitionResult`/`recognitionResultParameters`: origem dos parâmetros
  medidos e das métricas publicadas.
- `BridgeContext.attributes`: transporte runtime de proveniência sem mudar o
  contrato de seleção.
- `EditableSurfaceSelection`: fonte imutável da seleção inicial e da edição
  local por pincel, expandir/contrair e undo/redo.
- `runtime.showTransient`: ponto de preview transitório, sem persistência.
- `commands.dispatch('selection.set', ...)`: seleção global existente; não deve
  ser usada para confirmar correções paramétricas.

## Exemplos não implementados em C2

- Cilindro medido Ø17,798 → nominal Ø18,000 com eixo alinhado a Z.
- Plano inclinado → XY com offset conservando o plano medido como referência.
- Vetor reconhecido → direção Y do WCS.

Nenhum desses exemplos habilita criação CAD ou altera o resultado do fitter em
ER-P2C-C2.
