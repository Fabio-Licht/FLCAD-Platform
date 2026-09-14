# Inventário: importação STEP gerenciada

**Escopo:** STEP-0, auditoria e desenho de contrato. Este documento não introduz importador, comando visual, ABI ou mudança produtiva.

## Decisão de leitura

Há caminho seguro para uma primeira importação de STEP de arquivo único: alimentar \`STEPCAFControl_Reader::ReadStream()\` com um \`std::istream\` respaldado exclusivamente pelo source já admitido pelo CAF. A escolha é \`STEPCAFControl_Reader\`, não \`STEPControl_Reader\`: o primeiro preenche documento XDE (\`TDocStd_Document\`) com nomes, cores e estrutura; o segundo transfere principalmente geometria para \`TopoDS_Shape\`.

O caminho não existe no produto. O importador legado em \`native/opencascade/src/flcad_occ_api.cpp\` chama \`STEPControl_Reader::ReadFile(const char*)\`; depende de pathname, não produz o XDE necessário e não pode participar do fluxo managed. Nenhum fallback para ele é aceitável.

O menor STEP-1 seguro aceita uma peça de arquivo único, sem referências externas nem assembly, preserva BREP editável, nome da raiz, unidade e cor geral opaca. Cores por corpo ou face permanecem bloqueadas até existirem identificadores duráveis e proveniência de triângulos.

## Base verificável da auditoria

A árvore usa OCCT 8.0.1, configurado em \`build/occ_mesh_stream/CMakeCache.txt\` como \`C:/FLCAD/SDKs/OCCT/opencascade-8.0.1-vc14-64-combined/opencascade-8.0.1-vc14-64\`. Os símbolos abaixo foram inspecionados nos headers desse SDK e no código local.

| Área | Símbolos e evidência | Conclusão |
| --- | --- | --- |
| STEP geométrico | \`STEPControl_Reader::ReadFile\`, \`ReadStream\`, \`TransferRoot\`, \`SetSystemLengthUnit\` em \`STEPControl_Reader.hxx\` | Há leitura por stream, mas ela não basta para XDE. |
| STEP XDE | \`STEPCAFControl_Reader::ReadFile\`, \`ReadStream\`, \`Transfer\`, \`TransferOneRoot\`, \`SetColorMode\`, \`SetNameMode\`, \`SetPropsMode\`, \`GetShapeLabelMap\` | Há leitura XDE por stream e transferência para \`TDocStd_Document\`. |
| Cores | \`XCAFDoc_ColorTool::GetColor\`, \`SetColor\`, \`GetInstanceColor\`; \`Quantity_ColorRGBA\`; \`XCAFDoc_ColorGen\`, \`ColorSurf\`, \`ColorCurv\` | XDE representa cor RGBA em labels/shapes. Cobertura por subshape precisa de fixture. |
| Nomes e unidades | \`TDataStd_Name\`; \`XCAFDoc_LengthUnit::GetUnitName\`, \`GetUnitValue\`; \`XCAFDoc_ShapeTool::GetFreeShapes\`, \`GetComponents\`, \`GetSubShapes\` | Nome, unidade e topologia XDE são recuperáveis na importação. |
| Externos | \`STEPCAFControl_Reader::ExternFiles\`, \`ExternFile\` e \`ReadExternFile(file, fullpath, ...)\` | Há suporte multifile com resolução por caminho; STEP-1 deve recusá-lo. |
| Fonte admitida | \`flcad_occ_source.h\`, \`SOURCE_STREAM.md\`, \`BREP_STREAM.md\` | O bridge atual tem leitores source-managed apenas de BREP e STL; não há STEP. |
| Renderização | \`CadSceneEntity\` e \`_paintMeshBatched\` em \`professional_cad_viewport_widget.dart\` | A cena não carrega cor CAD genérica, por corpo ou face; usa cores padrão e dois sentinelas internos. |

## Fatos confirmados e hipóteses a validar

| Estado | Achado | Consequência |
| --- | --- | --- |
| Confirmado | \`STEPCAFControl_Reader::ReadStream(const char*, std::istream&)\` existe em OCCT 8.0.1. | O STEP principal não exige arquivo temporário. |
| Confirmado | O reader CAF habilita nomes, cores, layers e propriedades por padrão e transfere para XDE. | A extração ocorre do XDE antes de descartar o documento nativo temporário. |
| Confirmado | O reader possui rotinas para arquivos externos e uma recebe \`fullpath\`. | O nome lógico do stream não pode habilitar resolução; externos falham fechados. |
| Confirmado | O source bridge tem callbacks \`read_at\` e \`check\`, limites e cancelamento cooperativo, mas não exporta STEP. | STEP não cabe em Dart puro; fase posterior exige bridge nativo aprovado. |
| Confirmado | BREP e STL atuais não codificam nome, unidade XDE, RGBA ou associação de cor a corpo/face. | Um asset de aparência separado é obrigatório. |
| Confirmado | Ponteiro, token, \`TDF_Label\` e hash residente não sobrevivem a open. | Eles não podem entrar no documento, journal ou manifest. |
| Hipótese | Durante \`ReadStream\`, referência externa pode provocar resolução baseada no nome lógico. | Um protótipo deve provar recusa com fixture multifile e sem leitura externa. |
| Hipótese | \`Transfer\` tem progresso cooperativo; \`ReadStream\` não expõe \`Message_ProgressRange\` na assinatura vista. | Não prometer cancelamento durante parse antes de testar o adaptador e OCCT. |
| Hipótese | Cor por face pode estar em labels de subshapes para os arquivos alvo. | STEP-1B deve provar leitura e restauração por fixture. |

## Leitura segura e entrada hostil

O bridge futuro deve construir um \`std::streambuf\` sobre o handle CAF já admitido. O stream só chama callbacks da capability durante a operação ativa; não abre, reabre nem resolve pathname. \`ReadFile\`, arquivo temporário e nome de host não participam do contrato. O nome de \`ReadStream\` é um identificador lógico não resolvível, apenas diagnóstico.

Antes de publicar entidade, o reader deve conferir cancelamento e orçamento de bytes, converter \`Standard_Failure\`, erro C++ e cancelamento em causa específica, recusar referências externas, assemblies incompletos e múltiplas raízes no STEP-1A, aplicar limites para roots, labels, componentes, faces e strings, e descartar o XDE temporário em toda falha.

Os limites do source bridge para BREP/STL limitam o transporte, não todas as alocações do parser OCCT. Um STEP hostil ainda pode pressionar CPU e memória no parse/transfer. Limites estruturais, cancelamento cooperativo e política de tamanho são necessários; isolamento forte de processo é trabalho separado.

Assembly interna no mesmo stream é recusada por escopo no STEP-1A. Referência externa jamais ganha autoridade pelo nome lógico, diretório atual ou arquivo temporário: a importação inteira falha e não chama \`ReadExternFile\`. STEP-3 só poderá permitir dependência por lista explícita de assets CAF, cada qual com ID e hash.

## Dados CAD e limite da primeira versão

| Dado | Leitura XDE | Persistência/reabertura | STEP-1A |
| --- | --- | --- | --- |
| Geometria editável | Shape XDE para \`TopoDS_Shape\` | BREP managed canônico com hash | Sim |
| Malha de exibição | Gerada do shape | STL display asset com hash | Sim |
| Nome da peça | \`TDataStd_Name\` no root label | Campo do manifest | Sim |
| Unidade | \`XCAFDoc_LengthUnit\`: nome e escala para metro | Campo do manifest | Sim |
| Cor geral | \`ColorTool\` / \`Quantity_ColorRGBA\` | RGBA no manifest e adaptador de cena | Sim, opaca |
| Cor por corpo | Labels de shapes/subshapes e \`ColorTool\` | Seletor durável e batches | Não |
| Cor por face | Labels de subshapes quando presentes | Seletor durável e face→triângulos | Não |
| Transparência | RGBA XDE é representável | Renderer não persiste/aplica alpha por entidade | Não; recusar ou registrar não suportada |
| Assembly | \`ShapeTool\` expõe componentes/instâncias | Árvore de ocorrências persistida | Não |
| PMI, textura, PBR, material | Há modos XDE, sem contrato/renderizador local | Sem representação | Fora de escopo |

O STL é derivado e não serve para inferir aparência. BREP preserva geometria, mas não substitui o manifesto: o XDE de importação é temporário e labels podem mudar na reabertura.

## Contrato persistente proposto

Cada entidade STEP managed continua no ramo BREP managed: asset BREP canônico e asset STL de display. Acrescenta um terceiro asset imutável, JSON UTF-8 canônico, com hash persistido junto aos dois anteriores.

\`\`\`text
ManagedStepAssets v1
  shapeAssetId, shapeSha256
  displayMeshAssetId, displayMeshSha256
  appearanceAssetId, appearanceSha256
  meshOnly = false

StepAppearanceManifest v1
  schema = "flcad.step-appearance"
  version = 1
  root = { name }
  unit = { name, metersPerUnit }
  entityAppearance = { rgba } | null
  bodies = []
  faces = []
\`\`\`

\`appearanceAssetId\` identifica bytes imutáveis no armazenamento gerenciado; documento e journal registram somente IDs, hashes, versão e conteúdo serializável. Não registram CAF token, pointer, capability, \`TDF_Label\`, pathname, nome local, handle OCCT ou hash residente. Tipo de asset, codec canônico e migração são trabalho posterior.

No STEP-1A, \`bodies\` e \`faces\` ficam vazios. Para STEP-1B, cada entrada precisa de seletor determinístico derivado de conteúdo e estrutura canônicos — por exemplo, caminho de ocorrência e assinatura topológica versionada — com detecção de colisão e recusa por ambiguidade. Não é seguro usar ordem casual de \`GetSubShapes\`, \`TDF_Label\`, \`TopoDS_Shape\`/\`TShape\` ou ponteiro. A especificação e a prova de estabilidade após restaurar BREP são pré-requisitos.

Na importação futura, BREP, malha e manifesto entram no staging e só são promovidos juntos após validação. Save grava seus IDs/hashes na transação. Open e Redo validam os três antes de criar/publicar cena ou seleção; recriam shape e malha managed e aplicam manifest. Undo remove entidade e retenções de runtime, sem alterar assets. Close remove cena/retenção antes de dispose; o asset durável permanece para open/Redo.

## Renderização e menor adaptador

Hoje \`CadSceneEntity\` não tem cor serializável e \`_paintMeshBatched\` escolhe cor padrão por tipo, salvo \`destructiveRed\` e \`surfacePreviewBlue\`. O painter já gera cores por vértice, mas todas derivam de uma única cor de foreground.

O menor adaptador STEP-1A transporta RGBA validado do manifest para a geometria preparada/entidade de cena e faz o painter usá-lo para todos os vértices. A primeira versão aceita alpha 1.0; o bool \`transparent\` atual e alpha global do painter não são contrato de transparência por entidade.

Cor por corpo exige batches identificados por corpo, cada um com RGBA. Cor por face exige tabela de triangulação que relacione seletor persistido aos intervalos de triângulos. \`ManagedNativeDisplayMesh.prepareSceneGeometry\` não entrega proveniência. Ler cores no OCCT sem esses contratos não é suporte a cor persistida e renderizada.

## Integração com lifecycle managed

STEP entra como BREP managed, não como STL mesh-only nem pipeline legado:

1. admissão CAF concede fonte única e revogável;
2. bridge nativo lê stream XDE, valida escopo e captura shape/malha managed;
3. transação grava BREP, STL e manifest em staging, verificando tamanho e SHA-256;
4. promoção antecede commit documental, que referencia os três assets;
5. open/Redo recuperam somente por IDs e hashes; e
6. cancelamento, substituição e shutdown revogam fonte e impedem promoção/publicação.

Custody e leases existentes cobrem shape e malha. O manifest não tem owner nativo, mas integra a retenção transacional e não pode ser apagado enquanto snapshot o referencia. O XDE temporário não sai do bridge.

Os pontos de código novo são leitor STEP XDE source-managed e adaptador RGBA da cena. Body/face exigem seletor e proveniência. Se a proibição de mudança de ABI for permanente, existe bloqueio: a ABI atual não oferece STEP source-managed.

## Fases recomendadas

| Fase | Entrega | Pré-requisitos | Aceitação |
| --- | --- | --- | --- |
| STEP-1A | Peça única, BREP editável, nome, unidade e cor opaca. | Bridge \`ReadStream\`, RGBA, manifest v1, fixtures monopeça. | Sem \`ReadFile\`/temp path; sem externos/assembly; hashes BREP/STL/manifest; reabertura restaura valores. |
| STEP-1B | Cor por corpo e face persistida. | Seletor estável, proveniência de triangulação, batches, fixtures. | Cada cor encontra a região após save/open/Undo/Redo; ambiguidade falha fechada. |
| STEP-2 | Save/open/Undo/Redo completos. | 1A e matriz de falhas aplicada aos três assets. | Sem open/Redo parcial; hashes, retenções, owners e recovery preservados. |
| STEP-3 | Assemblies e dependências admitidas. | Árvore de ocorrências, conjunto CAF de assets por ID/hash. | Sem pathname; incompletude observável; instâncias/aparência restauram. |

## Testes necessários

| Tema | Prova requerida |
| --- | --- |
| Stream e autoridade | Spy prova \`ReadStream\`, callbacks CAF e zero \`ReadFile\`, temporário ou \`importStl(path)\`. |
| XDE | Fixtures com nome, unidade e cor geral comprovam extração e BREP editável. |
| Externos | Fixture multifile falha antes de transferência/publicação e sem acesso ao filesystem. |
| Hostil | Truncado, schema inválido, limites excedidos e \`Standard_Failure\` preservam causa e deixam staging/publicação limpos. |
| Cancelamento | Gates determinísticos em read/transfer provam que cancelamento, substituição e shutdown impedem promoção. |
| Persistência | Save/open/Undo/Redo conferem IDs, tamanhos e SHA-256 dos três assets; journal não contém token, pointer, capability ou pathname. |
| Cor geral | Reabertura produz RGBA do manifest no painter, sem cor padrão. |
| Corpo/face | STEP-1B: fixture prova seletor estável e face/cor mapeada para batches após reabertura. |
| Compatibilidade | BREP managed, STL mesh-only, legado e misto seguem seu ramo; STEP managed faz zero chamadas ao pipeline legado. |

## Revisão de segurança e bloqueios

A revisão de source/pathname conclui que somente CAF→stream→\`ReadStream\` é aceitável. O legado pathname é incompatível com a autoridade aprovada. Referências externas não recebem autoridade por nome lógico, diretório atual ou temporário; até existir resolvedor de assets CAF explícitos, são rejeitadas.

A revisão de persistência conclui que BREP/STL bastam para geometria e exibição monocromática, mas não aparência rica. O manifest hashado resolve nome, unidade e cor geral; não resolve corpo/face sem identidade de subshape e proveniência de malha. Declarar suporte a cor por face antes do STEP-1B seria incorreto.

Bloqueios para implementação: extensão versionada aprovada do bridge native STEP source-managed, validação de cancelamento no parse OCCT 8.0.1, prova de recusa de externos e adaptador de cor geral. STEP-1B ainda depende de seletor durável e mapeamento face→triângulos. Não há workaround seguro por pathname.
