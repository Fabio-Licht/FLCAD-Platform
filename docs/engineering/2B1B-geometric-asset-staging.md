# 2B1B — staging de assets geométricos

**Status: não aprovado.** A primeira etapa de remediação corrige revogação e
testes; o confinamento contra TOCTOU continua dependendo de um helper nativo
com operações ancoradas em handles. Não há liberação formal para 2B2.

## Remediação: revogação e drenagem

A primeira falha do produtor fecha admissão e revoga a operação sincronamente,
antes de aguardar trabalho admitido. O sinal privado de revogação acorda espera
por lock e por próximo chunk. Criações e avanços do journal validam autoridade
imediatamente antes da chamada de IO; essas validações são de ciclo de vida,
**não são uma correção de TOCTOU por pathname**.

No sucesso, tarefas admitidas são drenadas antes da revogação. No erro, nenhuma
nova intenção ou rename é autorizado. Um rename já concluído é registrado em
memória antes do próximo await e incluído na quarentena. Se a substituição do
journal já começou, seu resultado é relido antes da finalização; não se simula
rollback de uma syscall concluída. Assets promovidos permanecem retidos, mesmo
quando o produtor falha depois de committed.

Finalização ocorre uma única vez. Sua autoridade privada permite somente journal
de quarentena/rollback e descarte dos owners recebidos. Erro e stack do produtor
são preservados; falhas de cancelamento, descarte e journal são agregadas em
memória, sem persistir mensagens nativas. Uma falha no hook de cleanup não pula
as tentativas de dispose. O lock é liberado antes de aguardar leases.

Streams silenciosos têm a assinatura cancelada antes do fechamento do arquivo.
Uma escrita já iniciada é aguardada. Callbacks ou onCancel que nunca concluem
continuam exigindo cooperação do produtor; não se inicia cleanup concorrente
com escrita ativa para forçar shutdown.

Os testes adicionais cobrem falha do produtor com promoção admitida, fronteiras
do journal, preservação de movimentos reais, timeout sob contenção com deadline
controlado, sessão/revisão pelo validador puro usado em produção, colisões
determinísticas, destino vazio, stream sem eventos/depois de chunk confirmado
e shutdown aguardando lease. Matchers verificam causas específicas.

Permanece pendente do helper nativo: abertura/criação relativa a diretórios
validados, retenção da identidade dos ancestrais, IO e rename pelos mesmos
handles e proteção contra reparse em payloads, descriptors, journal, lock e
recovery. A integração deve provar que nenhuma entrada, nem arquivo vazio,
é criada fora da raiz numa troca concorrente de junction. Nenhum helper ou ABI
OpenCascade foi alterado nesta etapa.

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
