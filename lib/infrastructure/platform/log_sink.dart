/// The file logger: `main.log` in a directory the caller picks (production
/// passes the app-support/config dir). Ported host rules:
///  - rotated once at startup past 8 MB to `main.log.1`,
///  - each line clamped to 2000 bytes, cut on a character boundary, with a
///    note saying how much was cut,
///  - at most 20 000 lines per run, warning once at the cap,
///  - URLs lose their query strings and bearer tokens are blanked before
///    anything reaches disk,
///  - export copies the file out; reset truncates in place (same inode, so
///    an open tail keeps working).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/ports/app_log.dart';

class FileLogSink implements AppLog {
  FileLogSink(
    String directory, {
    this.maxFileBytes = 8 * 1024 * 1024,
    this.maxLineBytes = 2000,
    this.maxLinesPerRun = 20000,
  }) : _file = File(p.join(directory, 'main.log')) {
    Directory(directory).createSync(recursive: true);
    _rotateIfNeeded();
    _handle = _file.openSync(mode: FileMode.append);
  }

  final File _file;
  final int maxFileBytes;
  final int maxLineBytes;
  final int maxLinesPerRun;

  late RandomAccessFile _handle;
  int _linesThisRun = 0;
  bool _capWarned = false;

  String get path => _file.path;

  /// Rotation happens once, at startup: a run never rotates the file it is
  /// writing, so `main.log` always holds at least the whole current run.
  void _rotateIfNeeded() {
    if (!_file.existsSync() || _file.lengthSync() <= maxFileBytes) return;
    final rotated = File('${_file.path}.1');
    if (rotated.existsSync()) rotated.deleteSync();
    _file.renameSync(rotated.path);
  }

  /// Formats and writes one entry. Redaction is applied here — nothing
  /// reaches disk without it.
  @override
  void log(String level, String scope, String message) {
    final timestamp = DateTime.now().toIso8601String();
    write('[$timestamp] [$level] $scope: $message');
  }

  /// Writes one redacted, clamped line. Past the per-run cap, lines are
  /// dropped (with a single warning line saying so).
  void write(String line) {
    if (_linesThisRun >= maxLinesPerRun) {
      if (!_capWarned) {
        _capWarned = true;
        _append(
          'log line cap reached ($maxLinesPerRun lines this run); further lines dropped',
        );
      }
      return;
    }
    _linesThisRun++;
    _append(clamp(redact(line)));
  }

  void _append(String line) {
    _handle
      ..writeStringSync(line)
      ..writeStringSync('\n')
      ..flushSync();
  }

  /// Cuts a line down to [maxLineBytes] of UTF-8, on a character boundary,
  /// and says how much was cut.
  String clamp(String line) {
    final bytes = utf8.encode(line);
    if (bytes.length <= maxLineBytes) return line;
    // Walk back off any UTF-8 continuation bytes so the cut never splits a
    // character.
    var end = maxLineBytes;
    while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
      end--;
    }
    final kept = utf8.decode(bytes.sublist(0, end));
    return '$kept …[clamped ${bytes.length - end} bytes]';
  }

  /// Strips what must never be on disk: query strings (signed URLs put their
  /// tokens there) and bearer tokens.
  static String redact(String message) {
    var out = message.replaceAllMapped(RegExp(r'''https?://[^\s"'<>]+'''), (
      match,
    ) {
      final url = match[0]!;
      final query = url.indexOf('?');
      return query < 0 ? url : url.substring(0, query);
    });
    out = out.replaceAll(
      RegExp(r'[Bb]earer\s+[A-Za-z0-9._~+/=-]+'),
      'Bearer [redacted]',
    );
    return out;
  }

  /// Copies the log out as `zero-<epoch>.log` for a bug report.
  File export(String destinationDirectory) {
    _handle.flushSync();
    Directory(destinationDirectory).createSync(recursive: true);
    final destination = p.join(
      destinationDirectory,
      'zero-${DateTime.now().millisecondsSinceEpoch}.log',
    );
    return _file.copySync(destination);
  }

  /// Truncates in place — same inode, so anything tailing the file keeps
  /// working. The per-run line budget starts over.
  void reset() {
    _handle
      ..truncateSync(0)
      ..setPositionSync(0);
    _linesThisRun = 0;
    _capWarned = false;
  }

  void close() {
    _handle.closeSync();
  }
}
