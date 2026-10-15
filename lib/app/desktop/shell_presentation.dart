/// Textos de apresentação do shell principal.
///
/// Mantém a linguagem visível separada dos identificadores técnicos, sem
/// participar de dispatch, persistência ou contratos de domínio.
abstract final class ShellPresentation {
  static const product = 'FLCAD Reverse AI';
  static const welcome = 'Bem-vindo ao FLCAD Reverse AI';
  static const finish = 'Concluir';
  static const continueLabel = 'Continuar';
  static const back = 'Voltar';
  static const language = 'Idioma';
  static const portugueseBrazil = 'Português (Brasil)';
  static const english = 'Inglês';
  static const theme = 'Tema';
  static const dark = 'Escuro';
  static const light = 'Claro';
  static const defaultDirectory = 'Diretório padrão';
  static const projectDirectory = 'Diretório do projeto';
  static const chooseProjectDirectory =
      'Escolha um diretório de projeto em Configurações';
  static const searchTools = 'Pesquisar ferramentas';
  static const file = 'Arquivo';
  static const saveProject = 'Salvar projeto';
  static const closeProject = 'Fechar projeto';
  static const home = 'Início';
  static const workspace = 'Área de trabalho';
  static const settings = 'Configurações';
  static const openProject = 'Abrir projeto';
  static const noProjects = 'Nenhum projeto disponível.';
  static const settingsHint = 'Use Configurações na navegação lateral.';
  static const dashboard = 'Painel inicial';
  static const newProject = 'Novo projeto';
  static const cancel = 'Cancelar';
  static const create = 'Criar';
  static const projectName = 'Nome do projeto';
  static const client = 'Cliente';
  static const recentProjects = 'Projetos recentes';
  static const noRecentProjects =
      'Nenhum projeto recente. Abra ou crie um projeto para começar.';
  static const engineeringTip = 'Dica de engenharia';
  static const disableTips = 'Desativar dicas';
  static const openEngineeringWorkspace =
      'Abrir área de trabalho de engenharia';
  static const activities = 'Atividades';
  static const surfaceCommands = 'Comandos de superfície';
  static const createSurface = 'Criar superfície';
  static const surfaces = 'Superfícies';
  static const ready = 'Pronto';
  static const footer =
      'OpenCascade · Projeto em primeiro lugar · IA consultiva';
}
