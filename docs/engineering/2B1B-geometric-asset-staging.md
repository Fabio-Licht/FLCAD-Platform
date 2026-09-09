# 2B1B — staging de assets geométricos

Infraestrutura disponível por `CadRuntime.withGeometryStaging`. O runtime
captura a transação, sessão, revisão, documento e raiz canônica do projeto.
Nenhum produtor real foi migrado. A operação não publica documento ou cena.

## Layout e identidade

```text
<projeto>/
  .cad-staging/
    project.lock
    i1_<128 bits>/o1_<128 bits>/
      manifest.json
      manifest.previous.json
      files/ga1_<128 bits>/...
  CAD/Assets/v1/ga1_<128 bits>/
    asset.json
    shape.brep
    display.stl
    source/original.bin
    metadata.json
```

Os payloads são opcionais conforme o plano; um asset preparado precisa de
ao menos um arquivo. BREP e STL não podem ser vazios. IDs usam Random.secure,
não derivam de nomes externos e só admitem prefixo e 32 dígitos hexadecimais.
`GeometryAssetId` serializa schema, versão e referência; desserialização não
concede autoridade para escrever, remover ou liberar recursos nativos.

## Journal e estados

`preparing → prepared → commitIntent → promoting → committed` é o caminho de
promoção. Sem promoção, o encerramento segue `rollingBack → rolledBack` e
retém os arquivos. Falhas seguem para `quarantined`. Estados terminais nunca
retornam a ativos; uma falha tardia pode colocar um terminal em quarentena.

Cada atualização serializa integralmente um envelope com SHA-256, escreve
temporário exclusivo, faz flush e valida a leitura. O manifesto atual válido
é copiado por outro temporário para `manifest.previous.json`. Só depois o novo
manifesto substitui o atual por rename e é relido. A memória avança apenas
após confirmação. Checksum, versão, identidade, estado, sequência e contratos
de arquivos/promoted são verificados. Temporários incompletos são ignorados,
retidos e nunca adotados pela recuperação. Há limite de 1 MiB por manifesto.

Falhas são códigos não secretos. Owners, leases, ponteiros e tokens nativos
nunca são serializados. `asset.json` descreve identidade, projeto e hashes.

## Promoção e lock

Escritas e hashes usam streaming, com chunks de escrita limitados a 64 KiB.
Origens externas são borrowed: apenas lidas. Antes do commitIntent e de cada
rename, são revalidados contexto, confinamento, tamanho e SHA-256. Arquivos
inesperados impedem promoção. Destinos são conferidos novamente após mover.

O lock cooperativo usa arquivo persistente `.cad-staging/project.lock`, lock
real exclusivo de um byte e identidade diagnóstica escrita pelo mesmo handle.
Admissão local antecede abertura do arquivo; o SO arbitra outros processos.
Timeout e cancelamento são observáveis; reentrância é rejeitada. Projetos
diferentes não compartilham lock. Nenhuma instância apaga o lock. O SO libera
o lock ao encerrar o processo. Contenção externa usa polling limitado porque
Dart não oferece notificação de disponibilidade; testes usam barreiras.

A promoção sem sobrescrita desta fase suporta Windows com `MoveFileExW`,
WRITE_THROUGH, sem REPLACE_EXISTING e sem COPY_ALLOWED. Em outras plataformas
a promoção falha explicitamente. Staging e destino ficam sob a mesma raiz.
Nenhuma ABI C++/OpenCascade é alterada. Flush e rename não constituem promessa
de resistência absoluta a queda de energia: não há fsync explícito de diretório.

Links/junctions e ancestrais redirecionados são detectados por tipo e resolução
canônica. Esta é exclusão cooperativa; não protege contra processo hostil que
troque ancestrais entre a verificação e a operação de filesystem.

## Recuperação, ownership e fronteira 2B2

`inspectCadAssetStaging` é somente leitura. Usa backup válido conservadoramente;
manifesto inválido, promoção parcial ou falha registrada ficam em quarentena.
Assets completos com hashes válidos aguardam reconciliação documental, inclusive
em committed. Rollback significa retenção nesta fase, não exclusão. Não há GC,
reparo automático, limpeza de temporários ou remoção de arquivos legados.

Owners 2B1A podem ser transferidos para a operação somente em preparing. São
mantidos apenas em memória e descartados uma vez no encerramento, fora do lock.
Borrowed e leases não são aceitos como owners. Falha no dispose permanece
observável e coloca o journal em quarentena. Shutdown revoga o contexto, cancela
espera por lock e aguarda a fila e o descarte admitidos. Callbacks tardios ou
reentrantes não recuperam autoridade.

`PreparedGeometryAssets` devolve referências duráveis com
`documentPublished == false`. 2B2 deverá integrar publicação transacional e
reconciliação das referências antes de autorizar qualquer coleta. Upsert,
importação, duplicação, display, preview, Apply e transformações permanecem
inalterados. `NativeShapes` e `DisplayMeshes` continuam unmanaged e retidos;
não há migração automática nem conversão de handles legados.

## Verificação

`test/cad_asset_staging_test.dart` usa filesystem temporário real, kernel e
owners simulados, falhas injetadas, barreiras de concorrência e processo Dart
separado para o lock do SO. Abrange IDs, confinamento/junction, journals,
streaming, colisões, falhas de promoção, recuperação, cancelamento, shutdown
e custody. A regressão inclui os testes 2B1A e de runtime/repositório.
