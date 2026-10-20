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
