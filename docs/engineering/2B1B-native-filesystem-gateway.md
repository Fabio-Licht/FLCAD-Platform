# 2B1B: gateway nativo de assets

Integração opt-in na branch transacional, após merge normal de `dc1609e` sobre
`ff293e7`. A branch nativa e main permanecem preservadas; nenhum produtor 2B2
foi migrado. O 2B1B permanece formalmente não aprovado enquanto faltar a
qualificação real entre dois volumes NTFS. O teste com doubles não substitui
essa qualificação. Não foram criados VHDs nem alterados discos.

## Contrato e distribuição

`cad_asset_fs_native.dart` usa ABI C v1 (resultado de 96 bytes) e exige também
`caf_gateway_version() == 1` antes da aquisição da raiz. A extensão aditiva
oferece `caf_read`, `caf_entry`, `caf_lock` e `caf_create_pinned_dir`.
O DLL é construído, copiado ao lado do executável e instalado pelo CMake Windows.
O executável usa esse caminho absoluto; o harness pode selecionar um DLL por
`FLCAD_CAD_ASSET_FS_DLL`. Isso é seleção explícita do helper, nunca fallback.
Helper ausente, exportação ausente, ABI incompatível ou plataforma diferente
de Windows x64 falham antes da primeira mutação de assets.

A biblioteca permanece carregada por toda a vida do processo. Não existe
unload no gateway. Cada operação/recovery possui registro privado de capacidades,
fechado em finally, depois da drenagem de staging, lock e owners/leases. Dispose
é idempotente. Capacidades não são serializadas; somente volume e file ID,
tamanho e SHA-256 são metadados duráveis. Erros mantêm operação, status,
Win32/NTSTATUS, efeito concluído, bytes e identidade disponíveis; falha ao
fechar um recurso adquirido não substitui a causa primária.

## Fluxos ancorados

- Payload e descriptor: criação exclusiva, escrita limitada a 64 KiB por chamada,
  flush/hash/tamanho no mesmo objeto. Fecha-se o payload após seal e compara-se
  identidade/tamanho/hash na reabertura relativa, antes e depois da promoção.
- Journal: temporário exclusivo, flush, checksum e releitura pelo helper.
  Versões anteriores são renomeadas para `retained.j1_*.json` antes de instalar
  `manifest.previous.json` ou `manifest.json`. Nenhum rename substitui destino.
  Arquivos ativos permanecem abertos; leitores externos podem receber sharing
  violation. Backup inválido não autoriza limpeza. Falha no intervalo de rotação
  conserva backup e temporários, sem alegar atomicidade documental.
- Lock: arquivo ancorado em `.cad-staging`, criação exclusiva ou abertura
  existente, `LockFileEx` exclusivo não bloqueante no byte 0. Contenção na
  abertura e no lock segue timeout/cancelamento. Fechar somente o handle próprio
  libera o lock; o arquivo nunca é apagado. A chave local usa identidade da raiz.
- Promoção: somente diretórios de assets criados pela operação possuem DELETE.
  Diretórios estruturais são criados sem esse direito para permitir concorrência
  entre instâncias mantendo recusa de delete-sharing. Antes do rename de um
  asset, fecham-se handles descendentes; o próprio asset e ancestrais continuam
  ancorados. O resultado real é registrado antes do próximo await.
- Recuperação: enumeração e leitura por handles, sem mutação. Reparse ou estado
  ambíguo produz classificação conservadora; nenhum item autoriza exclusão.
  Manifestos antigos sem identidade completa não ganham confiança implícita.

Os objetos File/Directory remanescentes nos fluxos de assets são rótulos para
API/caminhos. A leitura de origem externa é borrowed. Não há create/write/rename/
delete por dart:io nesses fluxos. Save/open documental anterior permanece fora
deste gateway; esta fase não publica assets em documento/cena nem implementa GC.

## Revogação e limites

A revogação de `ff293e7` permanece síncrona. Cada avanço persistente reautoriza
após awaits. Uma syscall já iniciada retorna seu efeito real; não há rollback
fictício. Divergências são retidas e colocadas em quarentena, inclusive quando
um diretório já foi promovido. Recovery nunca tenta reparar ou excluir.

Hashing é streaming, mas a chamada nativa é síncrona: arquivos grandes atrasam
o isolate até ela retornar. Enumeração por índice reinicia a leitura do diretório
e tem custo quadrático; não promete snapshot contra alterações concorrentes.
Nenhuma dessas limitações concede autoridade para a próxima mutação revogada.
O confinamento não é sandbox contra injeção no processo, administrador ou ator
com autorização direta para reescrever o projeto depois da verificação.

## Validação reproduzível

Build/CTest Debug e Release: `native/cad_asset_fs`, 20 casos registrados,
19 aprovados e `caf_volume` pendente. Incluem processos atacantes reais,
reparse entre inspeção e syscall, inventário externo e ausência de arquivo vazio.
As falhas instrumentadas existem somente no executável de testes.

Testes Dart direcionados: `cad_asset_fs_gateway_test.dart`,
`cad_asset_staging_test.dart`, `native_allocation_custody_test.dart` e
`cad_runtime_transaction_test.dart`. O harness aponta explicitamente para o
DLL Debug ou Release. A biblioteca incompatível é um alvo somente de testes.
Incluem processo fresco sem helper/ABI divergente, corrida real no gateway,
divergência de identidade/tamanho/hash, colisão imediata, efeito pós-rename,
Unicode/caminho longo, recovery após save/open, revogação e shutdown com lease.

Referências auditadas: [LockFileEx](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-lockfileex)
e [GetFileInformationByHandleEx](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getfileinformationbyhandleex).
