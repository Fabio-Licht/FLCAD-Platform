# 2B1A — Custódia de alocações nativas CAD

Fundação Dart sobre a correção failure-atomic nativa `87bab03`, integrada em
`c224c73`. Não migra nenhum produtor existente e não modifica C++ ou assinaturas
FFI. O gateway é privado e compartilha a library Dart do adapter por `part`.

## Descritor e autoridade

`ShapeHandle` e `KernelMeshHandle` continuam descritores documentais. JSON,
`persistentId`, fingerprint e reconstrução de handles não criam ownership.
Não existe API pública para adotar um token ou um handle como owned.

`NativeAllocationIdentity` é final, tem construtor privado e vincula tipo
(shape/mesh), token concreto privado, geração da alocação e stamp da sessão.
O stamp é a identidade do gateway/coordenador proprietário daquela sessão;
não é a identidade de um adapter individual. A igualdade inclui todos esses
componentes. O mesmo persistentId pode descrever várias alocações. Reutilizar
um token após descarte não reutiliza a geração. Uma nova sessão tem outro stamp
e geração. Identidades não têm `toJson`; `toString` não inclui token.
Elas não são entity IDs, IDs duráveis de assets nem tokens serializáveis.

Somente o adapter chama o registro privado, imediatamente na continuação do
retorno bem-sucedido do bridge, antes de entregar o owner ao consumidor. A
aquisição entra no contador de operações antes da chamada ao bridge. Também
se registra uma aquisição já admitida quando o shutdown começa enquanto seu
resultado está pendente. Não há API de registrar novos recursos em um owner
transferido ou descartado: cada owner representa exatamente uma alocação.

O bridge injetado é a fronteira confiável, assim como a FFI. Uma implementação
de bridge fornecida pelo host deve retornar alocações novas conforme o contrato
failure-atomic. Tokens vazios, duplicados vivos ou sobrepostos ao conjunto legado
quarentenam a sessão; não se tenta destruir um token de identidade ambígua.

## Estados e descarte

| Origem | Ação | Resultado |
|---|---|---|
| owned | transfer | owner antigo transferred; novo owner owned da mesma alocação |
| owned | dispose | bloqueio imediato de novos leases/transferências; aguarda leases |
| descarte pendente | destroy confirmado | disposed |
| descarte pendente | exceção ou resultado incerto | quarantined, erro preservado |
| sessão quarantined | nova tentativa de destroy | rejeitada; recurso quarantined |

`OwnedNativeShape` e `OwnedNativeMesh` são tipos finais separados. Transferência
retorna um novo owner, revoga a credencial privada do antigo e não pode ser
revertida por ele. Leases existentes continuam pertencendo à mesma alocação.
O antigo owner não pode destruir, emprestar ou transferir outra vez.

`dispose()` publica e reutiliza a mesma Future antes de qualquer callback nativo,
inclusive em reentrância síncrona. A chamada destrutiva usa o registro capturado,
nunca lookup por persistentId ou ShapeHandle. Não há retry automático após erro;
`disposalError`, estado e Future rejeitada continuam observáveis. Quarantine não
equivale a disposed. Após sucesso, remove-se o registro vivo e liberam-se as
referências ao callback destrutivo e à sessão; a identidade retém apenas o stamp.
Recursos em quarantine são intencionalmente retidos para diagnóstico.

## Leases

`NativeShapeLease` e `NativeMeshLease` não oferecem destroy nem transferência.
Um lease se refere a uma alocação exata; release é síncrono e idempotente. O
contador fica na alocação, não no wrapper owner. Dispose bloqueia novos leases
imediatamente e aguarda o encerramento de todos os existentes.

`diagnoseOwned` valida sessão e release e mantém um pin interno durante a chamada
ao bridge: release do lease externo não permite destroy enquanto a operação
continua em voo. Um lease já concedido pode ser usado enquanto o owner aguarda
descarte e a participação ainda aceita operações. A política de shutdown bloqueia
novas operações na participação encerrando, mesmo com lease antigo; operações
já admitidas terminam e seus pins continuam válidos até liberação. Callback
tardio não reabre lease. Não há finalizer que libere ownership silenciosamente.

`custodyDiagnostics` expõe geração/estado da sessão, participantes, aquisições e
operações pendentes, alocações gerenciadas, leases, quarentenas e erro da sessão.
Lease vazado deixa unload pendente e aparece no contador, sem timeout destrutivo.

## Coordenação do registry global

Todos os adapters FFI que apontam para o mesmo `DynamicLibrary.handle.address`
usam a mesma chave estável do coordenador. Não se usa nome de arquivo, path ou
identidade do wrapper FFI para separar registries. A chave FFI não pode ser
substituída pelo caller. Bridges simulados usam identidade de objeto por padrão;
wrappers distintos do mesmo backend devem receber o mesmo objeto explícito
`nativeLibraryKey`. O host é responsável por não compartilhar essa chave entre
bibliotecas independentes.

Como statics Dart são locais ao isolate, a coordenação do registry process-wide
é hospedada exclusivamente no root isolate. `OpenCascadeFFI.load` rejeita outros
isolates via `RootIsolateToken`; adapters reais não devem ser construídos em
isolates auxiliares. Não se introduz ABI nativo de coordenação entre isolates.
O host não deve abrir FFI paralela fora deste adapter. Canais de comando para
outros isolates ficam para etapa futura.

Inicialização nativa tem Future única publicada antes da chamada reentrante.
Metadata (version/capabilities), diagnósticos e operações legadas também entram
no gate de participação. Descarregar A bloqueia novas operações de A e aguarda
as suas operações em voo; não descarrega o registry se B continua ativo.
O último participante fecha a admissão global e aguarda inicialização,
operações/aquisições, owners, destruições e leases antes de shutdown, uma vez.
Não há dependência circular entre a Future de unload e a de destroy.

Somente shutdown bem-sucedido remove a sessão do coordenador. Falha mantém
quarantine e Future/erro observáveis; novos adapters não podem abrir outra sessão
sobre registry incerto. O ABI atual de shutdown é void: o Dart não inventa um
código de retorno; exceções do bridge são observáveis, mas a chamada nativa
normal retornando não fornece confirmação adicional de erro interno.

## Integração mínima e compatibilidade

`createOwnedShape` é opt-in e não é chamado por produtores existentes.
`createOwnedMesh` oferece apenas a extensão confiável
`OpenCascadeManagedMeshNativeBridge`, exercitada pelo ledger simulado. A FFI real
não implementa esse produtor nesta etapa: a chamada é explicitamente rejeitada.
Não se implementou novo fluxo de importação/STL para obter um mesh gerenciado.

Os produtores existentes continuam registrando descritores nos mapas legados,
separados dos owners. `isUnmanaged`/`isUnmanagedMesh` identificam esses caminhos.
Recursos legados são conservadoramente retidos; sobrescrever um persistentId
não provoca destroy automático da alocação anterior. As operações explícitas
legadas de destroy/close permanecem compatíveis. O último shutdown nativo ainda
limpa o registry inteiro, como no uso normal com um único adapter, após drenar
todo uso conhecido. Não há conversão automática de handles antigos em owned.

## Verificação e próximos passos

`test/native_allocation_custody_test.dart` usa bridge/ledger exclusivamente
simulados. Registra tipo, token, geração, criação, destroy solicitado/concluído
ou falho, shutdown e snapshots de allocation ID, sessão/gateway, owner,
transferência, leases e estado. Completers tornam determinísticas as corridas;
não há sleeps. Tipos distintos também rejeitam mesh no acesso shape.

Os testes cobrem os 30 cenários do pedido, agrupando variantes (por exemplo,
dispose único/repetido/concorrente e release múltiplo/repetido), além de
reentrância, pins de uso e init/health em voo. A fronteira pública sem mint é
verificada com JSON/handles reconstruídos; a proibição de implementar os tipos
finais/construir credenciais privadas é garantida pelo compilador Dart.

2B1B ainda precisa definir a migração explícita dos produtores e dos consumidores,
custódia de meshes reais e escopos transacionais. Não há GC físico de documentos,
BREP/STL, staging, `.cad-staging`, manifesto ou assets versionados nesta etapa.
Importação, upsert, duplicateCollection, display/previews, Apply manual,
CommandManager, superfícies e Sketch não foram migrados.
