# Flutter CI

O workflow `.github/workflows/flutter-quality.yml` protege pull requests para
`main` e alterações enviadas diretamente à `main` com um gate reproduzível no
Windows.

O gate fixa Flutter 3.44.9 no canal stable e executa, nesta ordem:

1. `flutter pub get`;
2. `flutter analyze`;
3. `flutter test --reporter expanded`.

O cache fornecido por `subosito/flutter-action` reduz downloads entre execuções.
Execuções antigas da mesma branch são canceladas quando um novo commit é
enviado. Se o job falhar, os logs disponíveis são publicados como artifact por
14 dias.

## Limitação do gate

Este workflow não compila nem testa a integração nativa OpenCascade. O SDK OCCT
usado pelo projeto não está provisionado nos runners hospedados do GitHub e não
deve ser baixado implicitamente sem uma decisão sobre origem, versão, licença e
integridade do pacote. A validação nativa continua sendo um gate separado,
executado em uma máquina Windows provisionada com o SDK aprovado, até existir
uma estratégia reproduzível para o CI.
