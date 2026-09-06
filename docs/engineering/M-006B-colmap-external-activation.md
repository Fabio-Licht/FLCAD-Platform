# M-006B — Ativação experimental de COLMAP externo

## Entrega

- O gerenciador de backends inicia somente com `foundation`; nunca procura ou
  executa `colmap` implicitamente pelo `PATH`.
- Uma instalação já existente pode ser registrada apenas com autorização
  explícita, caminho absoluto, arquivo com nome esperado e self-test válido.
- O caminho é canonizado e persistido com origem `external`, estado
  `installed` e certificação `notCertified`.
- Descoberta e reabertura revalidam executáveis externos por existência e
  self-test, sem exigir que estejam dentro da raiz reservada às instalações
  gerenciadas.
- A ativação externa exige `allowUncertifiedExternal: true`, repete o probe de
  versão e fornece ao pipeline exatamente o executável autorizado.
- A versão detectada aparece nas capacidades e nos diagnósticos do backend.
- Uma preferência persistida por backend indisponível retorna com segurança ao
  backend `foundation`.

## Limites e segurança

Este recurso é experimental. `notCertified` significa apenas que o mecanismo
de self-test configurado aceitou o executável indicado. Nos testes herméticos
esse mecanismo é falso e não representa validação de um COLMAP real. Não há
confirmação de origem, assinatura, integridade, compatibilidade completa ou
segurança do binário externo.

A M-006B não inclui interface, download, instalador, busca automática no
`PATH`, ativação para produção nem smoke test com COLMAP real. Essas etapas
dependem de validação específica e de autorização do usuário.

Também permanecem fora deste marco: reforço da integridade das instalações
gerenciadas, mitigação completa da troca do executável entre validação e uso
(TOCTOU) e substituição do parâmetro booleano de autorização por uma capacidade
com identidade, escopo e validade auditáveis.
