# FLCAD Platform

Núcleo compartilhado da família de produtos FLCAD para aquisição técnica,
reconstrução 3D e engenharia reversa/CAD.

## Família de produtos

- **FLCAD Capture** — aplicativo móvel de aquisição de fotos, vídeos,
  medições e metadados.
- **FLCAD Scan** — domínio de reconstrução que transforma evidências em
  nuvens, malhas e resultados auditáveis. Não representa, por enquanto, um
  aplicativo separado já entregue.
- **FLCAD Reverse AI** — nome comercial vigente do ambiente de engenharia
  reversa e construção CAD editável.
- **FLCAD AI** — capacidades compartilhadas de assistência, análise e
  automação supervisionada. É uma capacidade/engine da Platform, não um novo
  produto que substitua o FLCAD Reverse AI. A decisão técnica e a validação
  continuam sob controle do profissional.

As responsabilidades, limites e nomenclatura oficiais estão em
[`docs/PRODUCT_ARCHITECTURE.md`](docs/PRODUCT_ARCHITECTURE.md). A decisão da
transição está registrada no
[`ADR-084`](docs/adr/ADR-084-flcad-platform-product-boundaries.md).

## Estado do repositório

O repositório GitHub chama-se **FLCAD-Platform**. A renomeação não altera ainda
identificadores técnicos legados: o package Dart `flcad_mobile`, o Android
`applicationId`, nomes de binários e a pasta local podem continuar com os nomes
atuais até uma migração específica, testada e aprovada.

## Documentação

- [Visão](docs/00_Vision.md)
- [Arquitetura](docs/01_Architecture.md)
- [Aquisição móvel](docs/03_Mobile.md)
- [Ambiente de desenvolvimento](docs/10_Development_Environment.md)
- [Architecture Decision Records](docs/09_ADR.md)
