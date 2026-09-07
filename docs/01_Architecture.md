# FLCAD PLATFORM

# Architecture

Versão: 1.0

Documento Oficial

Status: Em Desenvolvimento

---

# Objetivo

Este documento define a arquitetura oficial da plataforma FLCAD.

Seu objetivo é garantir que todos os produtos evoluam de forma consistente, escalável e independente.

---

# Visão Geral

A plataforma FLCAD é composta por produtos e domínios especializados sobre um
núcleo compartilhado. A taxonomia canônica está em
[`PRODUCT_ARCHITECTURE.md`](PRODUCT_ARCHITECTURE.md).

Cada módulo possui responsabilidades bem definidas.

```text
FLCAD Capture ── evidências ──> FLCAD Scan ── geometria ──> FLCAD Reverse AI
       │                              │                            │
       └──────────────────── FLCAD Platform ──────────────────────┘
                                      │
                                  FLCAD AI
```

---

# Produtos

## FLCAD Platform

Núcleo e repositório principal. Oferece contratos, domínio, persistência,
viewport, kernel CAD, reconstrução e integração sem representar uma única
interface de produto.

---

## FLCAD Capture

Responsável pela aquisição inteligente de dados.

Responsabilidades:

- Projetos
- Sessões
- Captura
- Organização
- Smart Measurements
- Exportação do contrato `.flscan` (nome histórico FLSCAN)

Não possui responsabilidade sobre:

- CAD
- Engenharia Reversa
- Superfícies

---

## FLCAD Scan

Responsável por validação da captura, fotogrametria, nuvens, malhas, escala e
diagnóstico. Neste momento é um domínio/produto, não um aplicativo separado já
entregue.

---

## FLCAD Reverse AI

Produto responsável pela engenharia reversa. Mantém o nome comercial definido
no ADR-065.

Responsabilidades:

- Processamento de Malhas
- Reconhecimento Geométrico
- Construção CAD
- Superfícies
- Preparação CAM
- Exportações CAD

---

## FLCAD Cloud

Serviço e infraestrutura planejados; não constituem uma entrega atual.

Escopo planejado:

- Sincronização
- Colaboração
- Compartilhamento
- Histórico
- Versionamento

---

## FLCAD AI

É a capacidade/engine de inteligência compartilhada da Platform. Pode apoiar
Capture, Scan e Reverse AI sem pertencer exclusivamente a uma interface e sem
constituir produto substituto. É supervisionada pelo profissional e não implica
autonomia infalível.

---

# Arquitetura Mobile

```text
Presentation

↓

Widgets

↓

Capture Manager

↓

Services

↓

Repositories

↓

Storage
```

---

# Arquitetura Reverse AI

```text
Presentation

↓

Application

↓

Engineering Brain

↓

Recognition

↓

Mesh

↓

Kernel

↓

Persistence
```

---

# Fluxo Geral

Objeto

↓

Captura

↓

Sessão

↓

Projeto

↓

FLCAD Scan

↓

FLCAD Reverse AI

↓

Reconstrução

↓

CAD

↓

CAM

↓

Fabricação

---

# Comunicação entre Produtos

A comunicação oficial será realizada utilizando o formato proprietário:

```text
.flscan
```

Esse formato será responsável por transportar:

- imagens;
- medições;
- metadados;
- sessões;
- projetos;
- IA;
- reconstruções futuras.

---

# Camadas

## Presentation

Interface com usuário.

Não contém regras de negócio.

---

## Domain

Contém as regras da plataforma.

Não depende da interface.

---

## Data

Responsável por persistência.

---

## Services

Integração com hardware.

Exemplo:

- câmera;
- GPS;
- sensores.

---

## AI

Inteligência Artificial.

Sempre desacoplada da interface.

---

# Princípios Arquiteturais

## Separação de responsabilidades

Cada módulo possui apenas uma responsabilidade.

---

## Alta coesão

Cada componente resolve apenas um problema.

---

## Baixo acoplamento

Componentes podem evoluir independentemente.

---

## Escalabilidade

Toda arquitetura deve suportar novos módulos sem refatorações profundas.

---

## Reutilização

Widgets.

Services.

Repositories.

Devem ser reutilizáveis.

---

# Estrutura Oficial

```text
lib

app

core

features

shared

theme

models
```

---

# Estrutura Features

```text
feature

presentation

widgets

domain

data

services
```

---

# Estrutura da IA

```text
AI

Capture AI

↓

Coverage AI

↓

Measurement AI

↓

Recognition AI

↓

Surface AI

↓

CAD AI

↓

CAM AI

↓

Productivity AI
```

Cada IA possui responsabilidade única.

---

# Formato de intercâmbio planejado

O contrato nativo planejado para intercâmbio é:

```text
.flscan
```

`FLSCAN` permanece o nome histórico desse formato/contrato sob o domínio FLCAD
Scan. Integrações também podem exigir formatos abertos ou APIs específicas.

---

# Escalabilidade

A arquitetura foi projetada para suportar:

- novos scanners;
- novos sensores;
- novos algoritmos;
- novas IA;
- novos formatos;
- novas plataformas.

Sem necessidade de alterar os módulos existentes.

---

# Filosofia

Uma funcionalidade nova nunca deve quebrar funcionalidades existentes.

Toda evolução deve ser incremental.

---

# Objetivo Final

Permitir que todos os produtos FLCAD funcionem como um único ecossistema.

Cada módulo poderá evoluir independentemente, mantendo compatibilidade através da arquitetura definida neste documento.

---

# Próximos Documentos

- Roadmap
- Mobile
- Reverse AI (FLCAD Reverse AI)
- AI
- Scan e formato `.flscan`
- Business

---

Fim do Documento
