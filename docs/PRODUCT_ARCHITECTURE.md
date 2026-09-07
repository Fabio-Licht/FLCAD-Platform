# Arquitetura de Produtos FLCAD

Status: Canônico
Data: 07/09/2026

## Propósito

Este documento define a nomenclatura e os limites atuais da família FLCAD. Ele
orienta novos documentos e implementações; documentos históricos continuam
válidos como registro do contexto em que foram escritos.

## FLCAD Platform

**FLCAD Platform** é o núcleo arquitetural compartilhado e o nome do
repositório principal. Ele concentra contratos, modelos de domínio,
persistência, viewport, kernel CAD, reconstrução, referências métricas e pontos
de integração usados pelos produtos FLCAD.

Platform não é sinônimo de um único aplicativo e não obriga todos os produtos
a usar a mesma interface ou o mesmo processo executável. Módulos podem ser
extraídos quando houver necessidade técnica comprovada, mantendo contratos
explícitos com o núcleo.

## Produtos e domínios

| Nome | Responsabilidade | Limite atual |
|---|---|---|
| **FLCAD Capture** | Aplicativo móvel de aquisição e organização de fotos, vídeos, medições e metadados | Não realiza engenharia reversa CAD profissional nem promete reconstrução métrica por si só |
| **FLCAD Scan** | Domínio/produto de reconstrução: validação da captura, fotogrametria, nuvem, malha, escala e diagnóstico | Não deve ser descrito como aplicativo separado já existente; sua forma de entrega ainda será definida |
| **FLCAD Reverse AI** | Produto de engenharia reversa: alinhamento, referências, reconhecimento geométrico, sketches, superfícies e sólidos CAD editáveis | Mantém o nome comercial definido no ADR-065 e não é o responsável primário pela aquisição móvel |
| **FLCAD AI** | Capacidade/engine compartilhada de orientação, diagnóstico, sugestão e automação supervisionada | Não é produto autônomo, não substitui o FLCAD Reverse AI nem a decisão, medição ou validação profissional |
| **FLCAD Cloud** | Serviço planejado de sincronização, colaboração, armazenamento e execução remota autorizada | É infraestrutura futura; não deve ser anunciado como serviço já entregue |

## Fluxo de valor

```text
FLCAD Capture
    aquisição e evidências
            ↓
FLCAD Scan
    reconstrução e avaliação
            ↓
FLCAD Reverse AI
    geometria CAD editável

FLCAD AI auxilia as três etapas como capacidade compartilhada da Platform.
```

Uma entrega pode usar somente parte desse fluxo. A separação existe para que
captura, reconstrução e engenharia reversa evoluam sem falsas equivalências:
uma coleção de fotos não é uma malha validada, e uma malha não é um modelo CAD
dimensional editável.

## Repositórios e compatibilidade

- `FLCAD-Platform` é o repositório principal desta base;
- `FLCAD-Capture` permanece o aplicativo Android de aquisição;
- FLCAD Scan e FLCAD Reverse AI são produtos/domínios sobre a Platform e não
  exigem novos repositórios neste momento;
- repositórios e protótipos anteriores permanecem como histórico e laboratório
  até que uma migração explícita aprove ou descarte seus componentes.

A mudança do nome do repositório é deliberadamente separada de uma migração de
identificadores. Permanecem, por enquanto:

- package Dart `flcad_mobile` e imports `package:flcad_mobile/...`;
- Android `applicationId` existente;
- nomes atuais de executáveis e artefatos;
- pasta local existente, como `C:\flcad_mobile`.

Alterar esses identificadores exige tarefa própria, análise de compatibilidade,
migração e testes. O nome visível da Platform não é autorização para uma troca
mecânica global.

## Regras de evolução

1. Novas funcionalidades devem declarar a qual produto/domínio pertencem.
2. Contratos compartilháveis pertencem à Platform; detalhes de interface
   permanecem no produto responsável.
3. Backends externos devem continuar substituíveis e explicitamente ativados.
4. IA deve explicar limites e preservar controle profissional.
5. Resultados estimados, reconstruídos e medidos devem manter proveniência e
   não podem ser apresentados como equivalentes.
6. Uma eventual separação física em novos repositórios será decidida por ADR,
   não presumida pelo nome do produto.
7. FLCAD Inspection e FLCAD CAM são extensões planejadas; sua menção não afirma
   implementação, disponibilidade ou compromisso de entrega.

## Autoridade documental

Este documento é a referência canônica para nomes e limites de produtos.
Detalhes técnicos permanecem nos documentos especializados e nos ADRs. Em caso
de conflito sobre a antiga exclusividade do Mobile ou sobre a taxonomia
histórica FLSCAN, prevalece o ADR-084. O nome comercial FLCAD Reverse AI
permanece regido pelo ADR-065.
