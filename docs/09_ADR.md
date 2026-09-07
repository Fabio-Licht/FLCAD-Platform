# FLCAD PLATFORM

# Architecture Decision Records

Versão: 1.0

Documento Oficial

Status: Ativo

Documento: 09_ADR.md

---

# Objetivo

Este documento registra as principais decisões arquiteturais da plataforma FLCAD.

Toda decisão estrutural importante deverá ser documentada para preservar o contexto, as alternativas avaliadas e os motivos da escolha.

---

# Como utilizar este documento

Cada ADR deverá conter:

- Identificador
- Data
- Status
- Contexto
- Decisão
- Consequências

---

# Status possíveis

- Proposto
- Aprovado
- Substituído
- Obsoleto

---

# ADR-001

## Título

Separação entre Mobile e Reverse AI

Status

Parcialmente substituído pelo
[ADR-084](adr/ADR-084-flcad-platform-product-boundaries.md)

---

### Contexto

Inicialmente foi considerada a possibilidade de realizar todo o processamento diretamente no aplicativo móvel.

Essa abordagem limitaria a evolução do sistema e aumentaria significativamente a complexidade do aplicativo.

---

### Decisão

Decisão histórica: o FLCAD Mobile seria responsável exclusivamente pela
aquisição inteligente de dados, e o processamento pesado permaneceria no
FLCAD Reverse AI. O ADR-084 preserva a separação de responsabilidades, mas
substitui a exclusividade associada aos nomes Mobile e Reverse AI.

---

### Consequências

Benefícios:

- arquitetura mais simples;
- menor consumo de recursos no dispositivo móvel;
- maior escalabilidade;
- evolução independente dos produtos.

---

# ADR-002

## Título

Formato proprietário FLSCAN

Status

Aprovado

---

### Contexto

Era necessário definir uma forma de transportar projetos completos entre diferentes componentes da plataforma.

---

### Decisão

Criar o formato proprietário:

```text
.flscan
```

---

### Consequências

Permite armazenar:

- projetos;
- sessões;
- fotografias;
- medições;
- metadados;
- reconstruções futuras.

---

# ADR-003

## Título

Arquitetura baseada em Features

Status

Aprovado

---

### Contexto

Aplicações Flutter muito grandes tornam-se difíceis de manter quando organizadas apenas por tipo de arquivo.

---

### Decisão

Organizar o projeto por Features.

Estrutura:

```text
feature

presentation

widgets

domain

data

services
```

---

### Consequências

- maior modularização;
- melhor reutilização;
- escalabilidade.

---

# ADR-004

## Título

Inteligência Artificial distribuída

Status

Aprovado

---

### Contexto

Uma única IA centralizada se tornaria excessivamente complexa.

---

### Decisão

Dividir a IA em especialistas.

Exemplos:

- Capture AI
- Coverage AI
- Recognition AI
- Surface AI
- CAD AI
- CAM AI
- Productivity AI

---

### Consequências

- evolução independente;
- melhor manutenção;
- maior clareza arquitetural.

---

# ADR-005

## Título

Produtividade como principal métrica

Status

Aprovado

---

### Contexto

O mercado costuma comparar softwares pela quantidade de funcionalidades.

---

### Decisão

A principal métrica da FLCAD será o tempo economizado pelo usuário.

Toda nova funcionalidade deverá responder:

> "Quanto tempo ela economiza?"

---

### Consequências

O desenvolvimento permanecerá focado na geração de valor.

---

# ADR-006

## Título

IA como copiloto

Status

Aprovado

---

### Contexto

Automatizações completas podem reduzir o controle do profissional.

---

### Decisão

A IA deverá sugerir.

O usuário deverá decidir.

---

### Consequências

- maior confiança;
- transparência;
- aceitação profissional.

---

# ADR-007

## Título

Documentação como parte do desenvolvimento

Status

Aprovado

---

### Contexto

Projetos de longa duração tendem a perder conhecimento ao longo do tempo.

---

### Decisão

Toda Sprint deverá produzir ou atualizar documentação oficial.

---

### Consequências

- preservação do conhecimento;
- onboarding facilitado;
- manutenção simplificada.

---

# Processo para novos ADRs

Sempre que uma decisão estrutural for tomada:

1. Criar um novo ADR.
2. Registrar o contexto.
3. Registrar as alternativas consideradas.
4. Registrar a decisão.
5. Registrar as consequências.

---

# Filosofia

Uma decisão arquitetural deve ser permanente, rastreável e compreensível.

Mesmo anos depois, qualquer desenvolvedor deverá entender por que determinada escolha foi realizada.

---

Fim do Documento
