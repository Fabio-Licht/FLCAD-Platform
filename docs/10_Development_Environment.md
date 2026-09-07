# Ambiente Homologado

Data: 11/08/2026

Após investigação em projeto mínimo foi homologado o ambiente oficial do
repositório hoje denominado FLCAD Platform.

## Compatibilidade de identidade

A mudança do nome do repositório não altera ainda o package Dart
`flcad_mobile`, o Android `applicationId`, nomes de binários nem a pasta local
(por exemplo, `C:\flcad_mobile`). Esses identificadores permanecem válidos até
uma migração técnica específica.

## Flutter

- Flutter 3.44.9
- Dart 3.12.2

## Android

- Android SDK 36
- Gradle 9.1
- Kotlin 2.3
- Temurin JDK 25

## Camera

Versão homologada:

camera 0.10.6

Backend:

camera_android

## Observação

A série camera 0.12.x utiliza camera_android_camerax e apresenta
incompatibilidade no ambiente atual
(CallbackToFutureAdapter not found).

Até nova homologação permaneceremos utilizando camera 0.10.6.
