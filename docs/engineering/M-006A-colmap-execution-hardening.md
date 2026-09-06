# M-006A — Endurecimento da execução COLMAP

## Entrega

- `workspacePath` é tratado como raiz de execuções, não como pasta de trabalho
  compartilhada.
- Cada chamada cria atomicamente um subdiretório exclusivo, mesmo quando duas
  reconstruções usam o mesmo identificador simultaneamente.
- O diretório de imagens e suas extensões são validados antes do primeiro
  processo externo.
- Cada comando só é aceito depois que seus artefatos mínimos existem e não
  estão vazios.
- O modelo esparso válido é descoberto pelo conteúdo, sem presumir o nome `0`.
- Diagnósticos contam somente nós `EvidenceNodeKind.capture`.
- Caminhos continuam absolutos e são enviados como argumentos literais, sem
  interpolação em shell.

## Limitação deliberada

Os subdiretórios de execução são retidos para inspeção, suporte e auditoria.
Política de expiração/limpeza, manifesto, persistência relativa, timeout,
encerramento de árvore de processos e certificação do executável não fazem
parte da M-006A e devem ser tratados em marcos posteriores.
