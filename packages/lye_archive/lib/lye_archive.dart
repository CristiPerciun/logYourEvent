/// Log Your Event (LYE) — archives.
///
/// Builds and verifies the ZIP packages of one subject chain (ADR-009), and
/// packs the readable journal of one day (ADR-012). Pure Dart: the console
/// can verify a package it has just downloaded without asking the server
/// anything.
library;

export 'src/archive_builder.dart';
export 'src/archive_row.dart';
export 'src/archive_verifier.dart';
export 'src/journal_day.dart';
