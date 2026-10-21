# FLCAD Automation Bridge — AB-01

Executor local supervisionado para uma única tarefa aprovada por execução.

## Interface

```powershell
pwsh -File tools/flcad_automation/executor.ps1 `
  -Task tools/flcad_automation/demo-task.json `
  -Worktree C:\FLCAD_WORKTREES\flcad-bridge
```

Validação sem execução:

```powershell
pwsh -File tools/flcad_automation/executor.ps1 `
  -Task tools/flcad_automation/demo-task.json `
  -Worktree C:\FLCAD_WORKTREES\flcad-bridge `
  -ValidateOnly
```

O executor aceita somente as ações tipadas `environment` e
`codex-environment-probe`. A segunda chama `codex exec` com `--sandbox
read-only` e `--ephemeral`, sem fornecer modelo, perfil, configuração ou
autenticação. O prompt do probe é fixo no executor; conteúdo da tarefa não é
tratado como shell ou prompt arbitrário.

Cada worktree possui um lock exclusivo `.flcad_automation.lock`. A tarefa
precisa estar em `approved`, declarar permissões proibidas como `false`, usar
um relatório JSON relativo e coincidir com a branch/HEAD esperados.

Relatórios e logs ficam no caminho indicado pela tarefa. A publicação GitHub
não faz parte do AB-01: sem `gh` autenticado com escrita, os relatórios ficam
locais.

## AB-03 — human intervention and GitHub Mobile

`prepare-intervention.ps1` accepts only `USER_TEST_REQUIRED`,
`USER_APPROVAL_REQUIRED` and `AGENT_BLOCKED`. Normal progress and successful
completion do not create notifications. `deduplication_id` prevents repeats
while an intervention is active; `-MarkHandled` records the operator response
without starting any task.

The default mode is `HEADLESS_DEVELOPMENT`. `GUI_TEST_REQUESTED` records that
GUI authorization is still not granted. This executor never controls mouse,
keyboard or monitors; any GUI control requires a separate explicit approval.

`github-transport.ps1` prepares an envelope for a native GitHub Issue with a
sanitized title, body and labels. It only reads the configured remote and the
presence of `gh`; it does not create an Issue, assign an operator or publish.
GitHub Mobile can notify the operator after a real Issue is created and
assigned, but that requires separate authorization.

## AB-02

`export-report.ps1` transforma o relatório do executor em um pacote de
publicação em `outbox/<task_id>`. O pacote contém apenas `report.json`,
`review-request.json`, `transport.json` e `manifest.json`; os hashes SHA-256
permitem verificar os bytes antes da revisão.

O exportador rejeita task IDs duplicados, HEAD/branch obsoletos, JSON inválido,
traversal e padrões de credencial. A simulação de publicação consulta somente
o remoto configurado e informa que a permissão de escrita não foi verificada;
nenhum `push` é executado.

Relatórios têm ciclo explícito: `local`, `prepared-for-publication`,
`published`, `awaiting-review`, `approved` ou `rejected`. O arquivo de revisão
é independente da execução e exige decisões separadas para testes, riscos e
critérios de aceitação. Nenhum comentário externo é interpretado como comando
ou autorização automática.
## AB-03-F1 — GitHub Actions transport

The local `.github/workflows/flcad-human-intervention.yml` is prepared only;
it is not active until an authorized operator reviews, commits, pushes and
dispatches it. The only trigger is `workflow_dispatch`, with `contents: read`
and `issues: write`. No checkout, push, comment or automatic Issue trigger is
used.

`actions-transport.ps1` emits a sanitized envelope with `publish=false` and
`dispatch_performed=false`; it never calls GitHub and never uses a token. The
previous Issue-create attempt returned HTTP 403 from the connected
integration, while Actions-permissions and branch-protection reads were also
blocked. Rulesets were readable and empty. These results do not prove future
`GITHUB_TOKEN` Issue-write capability, which must be confirmed before
activation.
## AB-04A — sanitized report transport

`publish-report.ps1` prepares only the sanitized `report.json`,
`review-request.json` and `manifest.json` under
`reports/<task_id>/v<version>` in a clean `automation/reports` worktree. It
does not add, commit or push; a later supervised Git step can publish the
prepared files. The package is allowlisted, its SHA-256 manifest is verified,
private paths, CAD/STL/log artifacts and credential-like content are rejected,
and a same task/version replay is idempotent while a different payload is a
conflict.

The report branch is separate from `main`. The ChatGPT GitHub connector can
read the published report files when they exist, but publication does not
trigger this conversation. Human decisions are represented independently by
`decision.schema.json` and must cite `task_id`, report SHA-256 and analyzed
commit. No report content is ever executed.

## AB-05A — report-bound Actions adapter

`actions-transport.ps1` accepts the AB-04C report-bound intervention and emits
the existing `workflow_dispatch` input envelope locally. Its `-DispatchRef`
defaults to `main`; this is separate from the source `branch` carried by the
intervention and identifies the ref containing the operational workflow. It carries
`report_version`, `report_sha256`, `report_url`, `commit`, `event`, `reason`,
`action_requested` and `deduplication_id`; `report_reference` is derived from
`report_url` for compatibility with the existing workflow input. The workflow
validates the report-bound fields when present and still requires
`publish=false`. No dispatch, Issue, notification or authorization is
performed by the adapter.

## AB-06A — local autonomous orchestration

`orchestrator.ps1` persists an allowlisted queue and delegates execution to
`executor.ps1`, then classifies the generated report with `classify-result.ps1`.
It accepts only tasks already in `approved`, keeps explicit state and attempt
count, serializes execution per worktree through the existing executor lock,
recovers `running` tasks as `queued`, enforces a timeout and stops safely at
`READY_FOR_REVIEW`, `WAITING_FOR_USER` or `BLOCKED`. It never executes report
content, shell text from a task, Git mutations, remote transport or Issues.

Start or resume one local cycle:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/flcad_automation/orchestrator.ps1 `
  -Command Run -QueuePath tools/flcad_automation/orchestrator-queue.json `
  -Worktree C:\FLCAD_WORKTREES\flcad-bridge
```

Add an authorized task with `-Command Add -Task <task.json>`; inspect the queue
with `-Command Status`; cancel with `-Command Cancel -TaskId <id>`; recover an
interrupted process with `-Command Recover`. A `READY_FOR_REVIEW` task requires
a review file bound to the exact task ID, report SHA-256 and analyzed commit via
`-Command Review`; no automatic reviewer is assumed.

## AB-06D — fixed Flutter headless actions

The executor allowlist includes exactly two fixed Flutter actions:

* `flutter-selection-latency` → `flutter test --no-pub --reporter expanded test/selection_latency_diagnostics_test.dart`
* `flutter-real-seed-matrix` → `flutter test --no-pub --reporter expanded test/er_p2c_c4_f1_real_seed_matrix_test.dart`

These actions are accepted only on the authorized functional worktree,
branch and commit. They do not accept command, path or argument overrides.
Raw output remains in the local controlled log; the structured report contains
only fixed-test evidence, exit code, duration, criteria and parsed metrics.
`convergence-failed` remains evidence and never becomes implicit approval.

To start a supervised continuous cycle after preparing two approved task JSON
files, use:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/flcad_automation/orchestrator.ps1 `
  -Command Run -QueuePath <queue.json> -Worktree C:\FLCAD_WORKTREES\flcad-bridge
```

For a persistent local watcher, without installing a Windows service:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/flcad_automation/orchestrator.ps1 `
  -Command Watch -QueuePath <queue.json> -Worktree C:\FLCAD_WORKTREES\flcad-bridge

powershell -NoProfile -ExecutionPolicy Bypass -File tools/flcad_automation/orchestrator.ps1 `
  -Command Pause -QueuePath <queue.json>
powershell -NoProfile -ExecutionPolicy Bypass -File tools/flcad_automation/orchestrator.ps1 `
  -Command Resume -QueuePath <queue.json>
powershell -NoProfile -ExecutionPolicy Bypass -File tools/flcad_automation/orchestrator.ps1 `
  -Command Stop -QueuePath <queue.json>
```

`Watch` writes `watch-heartbeat.json`, enforces one instance with
`watch.lock`, automatically submits ready reports to the independent reviewer,
and remains idle when the queue is blocked or empty. Recovery only requeues a
running task when its executor lock is absent.

For artifact safety, `Watch` blocks Flutter actions until a verified disposable
functional snapshot is supplied by a future isolation adapter. Direct `Run`
remains available for an explicitly supervised action, but continuous Watch
operation never runs Flutter against `C:\flcad_mobile` in place.
### Snapshot Flutter verificável

As ações Flutter do Watch só aceitam snapshots criados pelo adaptador fixo:

```powershell
powershell -File tools/flcad_automation/flutter-snapshot.ps1 -Command Create
powershell -File tools/flcad_automation/flutter-snapshot.ps1 -Command Verify -ManifestPath <snapshot>\snapshot-manifest.json
powershell -File tools/flcad_automation/orchestrator.ps1 -Command Status
powershell -File tools/flcad_automation/orchestrator.ps1 -Command Stop
```

O executor rejeita manifesto ausente, divergente, adulterado, com reparse point ou com caminhos não relocáveis. O teste de matriz real permanece bloqueado até que seus caminhos absolutos de fixture e artefato sejam tornados injetáveis.

### Operação diária persistente

Runtime padrão: `C:\Users\fabio\AppData\Local\FLCAD\automation-bridge-runtime`.

```powershell
$q='C:\Users\fabio\AppData\Local\FLCAD\automation-bridge-runtime\queue\daily-queue.json'
$w='C:\FLCAD_WORKTREES\flcad-bridge'

powershell -File "$w\tools\flcad_automation\orchestrator.ps1" -Command Watch -QueuePath $q -Worktree $w
powershell -File "$w\tools\flcad_automation\orchestrator.ps1" -Command Status -QueuePath $q -Worktree $w
powershell -File "$w\tools\flcad_automation\orchestrator.ps1" -Command Pause -QueuePath $q -Worktree $w
powershell -File "$w\tools\flcad_automation\orchestrator.ps1" -Command Resume -QueuePath $q -Worktree $w
powershell -File "$w\tools\flcad_automation\orchestrator.ps1" -Command Stop -QueuePath $q -Worktree $w
powershell -File "$w\tools\flcad_automation\orchestrator.ps1" -Command Recover -QueuePath $q -Worktree $w
```

Somente `flutter-selection-latency` e `flutter-real-seed-matrix` são ações Flutter permitidas. A matriz real pode terminar com `HUMAN_REVIEW_REQUIRED` quando registrar `convergence-failed`; isso interrompe a fila até decisão humana autorizada.

### AB-07A — decisão externa somente leitura

`external-decision.schema.json` define a decisão externa vinculada ao conjunto
exato `task_id`, `report_version`, `report_sha256` e `analyzed_commit`. Os únicos
valores de `decision` aceitos são `APPROVED`, `CHANGES_REQUESTED`, `BLOCKED` e
`HUMAN_REVIEW_REQUIRED`; campos extras, versões, commits, hashes, IDs ou decisões
desconhecidos são rejeitados.

O adaptador `read-external-decision.ps1` lê um JSON e o relatório local, verifica
os vínculos e pode consultar um ledger de deduplicação já existente. Ele não
escreve no ledger, não executa texto recebido, não altera a fila e não chama
GitHub. O resultado é sempre `authenticity=UNVERIFIED`, `authenticated=false`,
`forwarded=false` e `execution_authorized=false`. Portanto, um JSON, comentário
ou Issue publicado no GitHub nunca é tratado como aprovação automática. A
autorização futura exige uma prova de autoria verificável e uma permissão local
explícita, ainda inexistentes nesta Bridge.

Exemplo de leitura local:

```powershell
powershell -File tools/flcad_automation/read-external-decision.ps1 `
  -DecisionPath <decision.json> -ReportPath <report.json> `
  -TaskId <task_id> -AnalyzedCommit <40-hex> -ReportVersion <n> `
  -DeduplicationLedger <ledger.json>
```

O monitor de `automation/reports` permanece somente observador: pode detectar
relatórios e sinalizar intervenção, mas não publica decisões, não faz dispatch e
não controla o Watch. A Bridge também não dá ao ChatGPT acesso ao shell local.
