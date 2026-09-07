# M-006C1 — Controlador operacional experimental do COLMAP

## Entrega

Este marco introduz um controlador `ChangeNotifier` isolado da pilha alpha. Ele
exige consentimento e autorização experimental explícitos, registra o backend
somente depois de uma ativação válida e executa exclusivamente a seleção manual
`colmap`. O controlador expõe estados, relatórios imutáveis, resultado, erro,
cancelamento e repetição de uma tentativa.

Uma reconfiguração valida integralmente o novo executável antes de substituir
atomicamente um backend já funcional. Se a nova ativação falhar, o backend
anterior permanece registrado e pronto, enquanto o erro continua disponível
para diagnóstico.

O runner de processos continua usando argumentos literais e `runInShell: false`.
Ao cancelar, tenta encerrar apenas o PID iniciado, espera brevemente sua saída e
finaliza as assinaturas de stdout/stderr. Isso é *best effort*: não há garantia de
encerramento da árvore de subprocessos.

## Limites honestos

- Não há interface gráfica neste marco.
- Não houve smoke test com uma instalação real do COLMAP.
- Não há timeout global, limite de logs ou encerramento garantido da árvore.
- O resultado é um candidato de malha, não um sólido CAD editável, reparado ou
  dimensionalmente certificado.
- `diagnostics.confidence` hoje representa somente conclusão técnica dos
  estágios/artefatos. Não representa precisão, qualidade geométrica ou uma
  porcentagem de confiança para o usuário.
- O redesenho do contrato de confiança/qualidade permanece no backlog posterior
  à M-006C1.
