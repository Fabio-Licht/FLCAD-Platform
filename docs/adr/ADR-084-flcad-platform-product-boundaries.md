# ADR-084 — FLCAD Platform e limites dos produtos

Status: Accepted — 2026-09-07

## Contexto

O repositório originalmente denominado `FLCAD-Mobile` passou a conter o núcleo
Flutter/Desktop, viewport CAD, integração OpenCascade, contratos de
reconstrução, referências métricas e infraestrutura compartilhada. Seu nome já
não representava o escopo real.

Ao mesmo tempo, o aplicativo móvel de aquisição passou a ter identidade própria
como FLCAD Capture. FLCAD Scan e FLCAD Reverse AI precisam de limites claros
para evitar confundir captura, reconstrução de malha e produção de CAD editável.

O ADR-001 de `docs/09_ADR.md` decidiu que o FLCAD Mobile seria exclusivamente
responsável pela aquisição e que todo processamento pesado pertenceria ao
Reverse AI. A experiência e a arquitetura atual mostram que a separação entre
aquisição e processamento continua útil, mas essa associação exclusiva entre
nomes ficou obsoleta.

## Decisão

- O repositório principal passa a se chamar `FLCAD-Platform`.
- FLCAD Platform é o núcleo compartilhado, não um produto monolítico.
- FLCAD Capture é o aplicativo móvel responsável pela aquisição.
- FLCAD Scan é o domínio/produto de reconstrução; não se afirma que já exista
  como aplicativo separado.
- FLCAD Reverse AI mantém o nome comercial vigente, definido pelo ADR-065, e é
  o produto de engenharia reversa e CAD editável. Este ADR não o renomeia.
- FLCAD AI é uma capacidade/engine compartilhada de assistência e automação
  supervisionada; não é um produto substituto, não representa autonomia mágica
  nem substituição do profissional.
- FLCAD Cloud é infraestrutura/serviço planejado, não uma entrega atual.
- FLCAD Inspection e FLCAD CAM permanecem extensões planejadas; sua inclusão na
  arquitetura não afirma implementação ou disponibilidade.
- O processamento pesado pode executar em desktop, servidor ou outro backend
  autorizado, conforme requisitos técnicos, sem ser atribuído por definição a
  um único produto.

Esta decisão substitui **somente** a parte do ADR-001 que torna “FLCAD Mobile”
exclusivamente aquisição e atribui todo processamento pesado ao “Reverse AI”.
A motivação histórica, a separação de responsabilidades e o registro original
são preservados.

Também substitui somente a taxonomia de produto do roadmap histórico FLSCAN:
**FLCAD Scan** passa a ser o nome canônico do domínio/produto. `FLSCAN` continua
válido como nomenclatura histórica e como nome do formato/contrato de
intercâmbio `.flscan`. O roadmap original permanece preservado como registro.

Este ADR não substitui nem modifica o ADR-065.

## Compatibilidade

A renomeação do repositório não renomeia agora:

- package Dart `flcad_mobile`;
- Android `applicationId`;
- binários e artefatos existentes;
- pastas de trabalho locais, incluindo `C:\flcad_mobile`.

Essas mudanças ficam fora do escopo e exigem migração específica.

## Consequências

- documentação e novas tarefas passam a usar a taxonomia oficial;
- Capture, Scan e Reverse podem evoluir sobre contratos comuns;
- não é necessária uma divisão prematura em múltiplos repositórios;
- documentos históricos não serão reescritos em massa;
- referências técnicas legadas continuam funcionando;
- futuras extrações de módulos ou renomeações técnicas precisarão de ADR e
  validação próprios.
