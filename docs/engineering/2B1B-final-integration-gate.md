# Gate Windows do 2B1B — 2026-09-09

Escopo revisado somente leitura: `ff293e7..1445129`, com foco em
instalação/carregamento e execução real. Os ajustes deste gate são apenas
entrypoint de teste, harness e esta evidência; nenhuma API produtiva mudou.

## Inventário Git

`git show --stat --name-status 1445129` contém exatamente estes 15 arquivos:

| Arquivo | Alteração |
|---|---|
| docs/engineering/2B1B-native-filesystem-gateway.md | adicionado |
| lib/app/runtime/cad_asset_fs_native.dart | adicionado |
| lib/app/runtime/cad_asset_staging.dart | modificado |
| lib/app/runtime/cad_asset_storage.dart | modificado |
| lib/app/runtime/cad_runtime.dart | modificado |
| native/cad_asset_fs/CMakeLists.txt | modificado |
| native/cad_asset_fs/README.md | modificado |
| native/cad_asset_fs/include/cad_asset_fs.h | modificado |
| native/cad_asset_fs/src/cad_asset_fs.cpp | modificado |
| native/cad_asset_fs/tests/abi_incompatible.c | adicionado |
| native/cad_asset_fs/tests/test_main.cpp | modificado |
| test/cad_asset_fs_gateway_test.dart | adicionado |
| test/cad_asset_staging_test.dart | modificado |
| test/support/cad_asset_fs_probe.dart | adicionado |
| windows/CMakeLists.txt | modificado |

O merge `f51f02d` tem pais `ff293e7` e `dc1609e`. O commit nativo
`dc1609e` adicionou sete arquivos em `native/cad_asset_fs`: CMakeLists.txt,
README.md, include/cad_asset_fs.h, src/cad_asset_fs.cpp, src/identity_policy.h,
tests/abi_c.c e tests/test_main.cpp. A união do intervalo revisado tem 17 arquivos.

`C:\Users\fabio\AppData\Local\Temp\integrate_caf.py` está fora do worktree.
Seu hash de blob, `5ac0b1d0e73eaa757406309d22f34aac433ea22a`, não aparece
na árvore de `1445129` e nem existe como objeto Git neste repositório.
Nenhum arquivo de Temp, `build/` ou `.dart_tool/` está versionado no conjunto integrado.

`build/`, `.dart_tool/` e `windows/flutter/ephemeral/` estão ignorados.
Não foram versionados os executáveis, DLLs, logs ou projetos deste gate.
Há dois artefatos legados anteriores ao 2B1B, preservados sem alteração:
`.codex_tools/imageio_ffmpeg/binaries/ffmpeg-win-x86_64-v7.1.exe` e
`android/build/reports/problems/problems-report.html`. Portanto não se afirma
que o repositório inteiro nunca conteve artefatos gerados.

## Build completo e execução

Comandos suportados, incluindo Flutter AOT, runner, plugins, bibliotecas,
cópia de DLLs e instalação do bundle:

```powershell
flutter --suppress-analytics build windows --release --no-pub -t lib/main.dart
flutter --suppress-analytics build windows --release --no-pub -t test/support/cad_asset_app_smoke.dart
powershell.exe -NoProfile -ExecutionPolicy Bypass -File test/support/run_cad_asset_app_smoke.ps1 -BundlePath C:\flcad_mobile\build\windows\x64\runner\Release
```

A política de execução acima vale somente para o processo do harness; não
modifica a política persistente da máquina. O build padrão é restaurado após
o smoke. O bundle de teste é preservado separadamente, fora do repositório.

O aplicativo usa o runner e `FLCADDesktopApplication` reais. A configuração
de teste mantém a tela FirstRunWizard, valida assets reais e injeta settings
descartáveis. Não inicializa o bootstrap produtivo nem registra kernels.
O processo foi inspecionado: `flcad_opencascade.dll` não estava carregado.
Não se trata de teste de geometria ou de uso manual do workspace de modelagem.

O harness exige ausência de override `FLCAD_CAD_ASSET_FS_DLL`, observa o módulo
que o próprio staging carregou e compara seu caminho ao bundle. ABI e gateway
são consultados no módulo já carregado: ambos retornaram **1**.

Evidência final:

- Raiz exclusiva: `C:\Users\fabio\AppData\Local\Temp\flcad-caf-app-gate-048bceb82d6b4b3295f447c684ed4d39`.
- PID **15416**, status **PASS**, saída normal **0**, processo encerrado.
- DLL: `C:\flcad_mobile\build\windows\x64\runner\Release\cad_asset_fs.dll`.
- Asset: `ga1_0062787a8cc754055e71c87d51495332`.
- Payload sintético `source/original.bin`: **131079 bytes**, três chunks.
- SHA-256: `14959b78e9a3db42d9708e444df7e55a1af4584ec8b4f967b009843c3fb738d3`.
- Escrita, seal, lock, commitIntent, rename e journal committed observados.
- Recovery pelo helper verificou volume/file ID, tamanho e hash.
- O harness leu os bytes independentemente, comparou o padrão sintético e SHA-256.
- Shutdown repetido terminou; rename do projeto e retorno ao nome original
  passaram antes do fechamento da janela. Todo handle do helper conserva o
  projeto sem SHARE_DELETE; o probe evidencia que essas capacidades foram drenadas.
- Antes do WM_CLOSE havia 431 handles normais do processo/UI. Depois, o processo
  terminou; não se confunde esse total com handles pendentes do staging.

Relatórios: `smoke-result.json`, `process-result.json`, stdout/stderr e cópia
`smoke-bundle/` dentro da raiz exclusiva. Não há fallback Dart: o carregamento
foi observado no bundle e a revisão confirmou falha explícita sem helper/ABI.

O primeiro ensaio completou staging, mas `SystemNavigator.pop` não encerrou o
runner Windows. O harness foi corrigido para enviar WM_CLOSE somente à janela
do processo que criou, depois do relatório pronto, e conferir exit code. Não
foi usado TerminateProcess nem encerrado qualquer processo alheio.

## Revisão e decisão

| Verificação final | Resultado |
|---|---|
| Build Windows completo padrão, restaurado com lib/main.dart | PASS, exit 0, 105,1 s |
| Build Windows completo da configuração de smoke | PASS, exit 0, 111,5 s |
| Smoke no processo Windows real | PASS, exit 0 |
| cad_asset_staging_test.dart após build, DLL do bundle | 61 aprovados, exit 0 |
| Flutter analyze --no-pub | sem problemas |
| Formatação e git diff --check | aprovados |

Conclusão do gate local: **aprovado para iniciar o 2B2**. Não equivale a
liberação pública do backend Windows em volumes ainda não qualificados.

Revisão final somente leitura: dependência do runner no target cad_asset_fs,
cópia e instalação adjacentes ao executável, carregamento por caminho absoluto,
negociação antes de adquirir a raiz, DLL residente e drenagem das capacidades.
O smoke verifica o executável empacotado, exige relatório PASS e saída zero;
não aceita a existência de alguns arquivos como prova de sucesso.

O teste real entre dois volumes NTFS continua **pendente para liberação
pública**. Nenhum VHD/disco foi criado ou alterado; doubles não foram
apresentados como evidência real. A autorização para começar o 2B2 é um gate
interno separado dessa qualificação pública. Nenhum trabalho do 2B2 foi iniciado.
