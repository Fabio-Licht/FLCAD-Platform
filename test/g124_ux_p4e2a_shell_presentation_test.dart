import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/app/desktop/shell_presentation.dart';

void main() {
  test('shell presentation uses concise Portuguese labels', () {
    expect(ShellPresentation.workspace, 'Área de trabalho');
    expect(ShellPresentation.searchTools, 'Pesquisar ferramentas');
    expect(ShellPresentation.openProject, 'Abrir projeto');
    expect(ShellPresentation.newProject, 'Novo projeto');
    expect(ShellPresentation.settings, 'Configurações');
    expect(ShellPresentation.finish, 'Concluir');
    expect(ShellPresentation.continueLabel, 'Continuar');
    expect(ShellPresentation.back, 'Voltar');
    expect(ShellPresentation.activities, 'Atividades');
  });

  test('technical product terminology remains stable', () {
    expect(ShellPresentation.product, 'FLCAD Reverse AI');
    expect(ShellPresentation.footer, contains('OpenCascade'));
    expect(ShellPresentation.surfaces, 'Superfícies');
  });
}
