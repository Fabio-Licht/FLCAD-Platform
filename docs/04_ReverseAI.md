# FLCAD PLATFORM

# Reverse AI

> **Nomenclatura vigente:** FLCAD Reverse AI continua sendo o nome comercial do
> produto, conforme o ADR-065. FLCAD Platform é o núcleo compartilhado; FLCAD
> AI é uma capacidade/engine compartilhada e não substitui este produto. Consulte
> [PRODUCT_ARCHITECTURE.md](PRODUCT_ARCHITECTURE.md) e o
> [ADR-084](adr/ADR-084-flcad-platform-product-boundaries.md).

Versão: 1.0

Documento Oficial

Status: Em Desenvolvimento

Documento: 04_ReverseAI.md

---

# Objetivo

O FLCAD Reverse AI é o produto responsável por transformar malhas
tridimensionais em modelos CAD editáveis voltados à engenharia reversa. Recursos
paramétricos avançados, Inspection e CAM dependem de seus respectivos marcos e
não são afirmados como entregues por este documento.

Seu propósito é reduzir drasticamente o trabalho manual atualmente necessário em softwares de Engenharia Reversa.

---

# Missão

Automatizar a reconstrução CAD utilizando Inteligência Artificial sem retirar do profissional o controle sobre o processo.

---

# Filosofia

O objetivo não é simplesmente converter uma malha em CAD.

O objetivo é compreender a geometria da peça.

O software deve reconhecer intenção geométrica.

---

# Fluxo Geral

Objeto

↓

Scanner

↓

Malha

↓

FLCAD Reverse AI

↓

Reconhecimento

↓

Referências

↓

Sketch

↓

Superfícies

↓

CAD

↓

CAM

---

# Arquitetura Geral

```text
Presentation

↓

Application

↓

Engineering Brain

↓

Recognition Engine

↓

Surface Engine

↓

Mesh Engine

↓

Kernel

↓

Persistence
```

---

# Engineering Brain

O Engineering Brain é o coordenador de toda a plataforma.

Responsabilidades:

- planejamento;
- execução;
- priorização;
- automação;
- IA.

Ele distribui tarefas para motores especializados.

---

# Recognition Engine

Responsável por identificar automaticamente elementos geométricos.

Planejamento:

- planos;
- cilindros;
- cones;
- esferas;
- toros;
- regiões orgânicas.

---

# Region Engine

Responsável por dividir a malha em regiões coerentes.

Cada região possui:

- área;
- orientação;
- normal média;
- variância;
- densidade;
- qualidade.

---

# Plane Recognition

Pipeline oficial:

Região

↓

Plano Candidato

↓

Plane Fitting

↓

Plane Validation

↓

Reference Plane

---

# Surface Engine

Responsável pela reconstrução de superfícies.

Planejamento:

- planas;
- cilíndricas;
- cônicas;
- esféricas;
- NURBS;
- orgânicas.

---

# Reference System

Toda engenharia será baseada em referências.

Tipos:

- Plano
- Eixo
- Ponto
- Sistema de Coordenadas

---

# Sketch Engine

Responsável pela criação de Sketches.

Planejamento:

## Sketch 2D

Linhas

Arcos

Círculos

Restrições

---

## Sketch 3D

Curvas

Eixos

Planos

Interseções

Perfis

---

# Construction Geometry

Planejamento:

- Plano por 3 pontos
- Plano por região
- Plano por melhor ajuste
- Eixo por cilindro
- Eixo por interseção
- Ponto por interseção
- Sistema de coordenadas

---

# Mesh Engine

Responsável por:

- importação;
- estatísticas;
- qualidade;
- Octree;
- consultas espaciais.

---

# Spatial Engine

Responsável por consultas rápidas.

Estruturas previstas:

- Octree
- Bounding Box
- Radius Query
- Nearest Neighbor

---

# Surface Workflow

Malha

↓

Reconhecimento

↓

Referências

↓

Sketch

↓

Superfícies

↓

Sólido

↓

STEP

---

# Exportações

Planejamento:

- STEP
- IGES
- Parasolid
- STL
- OBJ
- PLY

---

# Integração

Formato oficial:

```text
.flscan
```

---

# IA

Especialistas previstos:

Capture AI

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

---

# Objetivo da IA

A IA deverá:

- sugerir referências;
- reconhecer geometrias;
- propor superfícies;
- acelerar modelamento;
- reduzir decisões repetitivas.

O profissional sempre poderá aceitar ou rejeitar sugestões.

---

# Performance

Objetivos:

- milhões de triângulos;
- processamento incremental;
- memória otimizada;
- arquitetura paralelizável.

---

# Roadmap

Genesis

↓

Recognition

↓

Surface

↓

Sketch

↓

CAD

↓

CAM

↓

IA Completa

---

# Integração com Mobile

O FLCAD Capture é responsável pela aquisição. O FLCAD Scan é o domínio canônico
de reconstrução de nuvens e malhas. O FLCAD Reverse AI recebe a geometria e as
evidências para a reconstrução CAD editável.

A comunicação ocorrerá através do formato:

```text
.flscan
```

---

# Objetivo Final

Permitir que um profissional transforme uma malha tridimensional em um modelo CAD paramétrico com o mínimo possível de trabalho manual.

---

# Definição de Sucesso

O Reverse AI será considerado bem-sucedido quando:

- reduzir drasticamente o tempo de modelamento;
- aumentar a produtividade do profissional;
- produzir modelos CAD confiáveis;
- integrar-se perfeitamente ao ecossistema FLCAD.

---

# Visão de Longo Prazo

O FLCAD Reverse AI evoluirá de um software de Engenharia Reversa para um Assistente Inteligente de Engenharia.

Seu objetivo será compreender a intenção geométrica do usuário e automatizar progressivamente todo o processo de reconstrução, mantendo o profissional no controle das decisões.

---

Fim do Documento
