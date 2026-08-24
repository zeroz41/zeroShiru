import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zeroshiru/infrastructure/platform/log_sink.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('zeroshiru-log-test');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  List<String> lines() => File(p.join(dir.path, 'main.log')).readAsLinesSync();

  test('lines land in main.log', () {
    final sink = FileLogSink(dir.path);
    sink.write('hello');
    sink.log('info', 'boot', 'started');
    sink.close();
    final written = lines();
    expect(written[0], 'hello');
    expect(written[1], contains('[info] boot: started'));
  });

  group('clamping', () {
    test(
      'a long line is cut to the byte budget with a note of how much was cut',
      () {
        final sink = FileLogSink(dir.path);
        sink.write('x' * 3000);
        sink.close();
        final line = lines().single;
        expect(line, startsWith('x' * 2000));
        expect(line, contains('[clamped 1000 bytes]'));
      },
    );

    test('the cut lands on a character boundary', () {
      final sink = FileLogSink(dir.path);
      // '€' is 3 UTF-8 bytes; 667 of them straddle the 2000-byte budget.
      sink.write('€' * 667);
      sink.close();
      final line =
          lines().single; // readAsLinesSync would throw on broken UTF-8
      expect(line, startsWith('€' * 666));
      expect(line, contains('[clamped 3 bytes]'));
    });

    test('a short line is untouched', () {
      final sink = FileLogSink(dir.path);
      sink.write('short');
      sink.close();
      expect(lines().single, 'short');
    });
  });

  group('per-run line cap', () {
    test('warns once at the cap and drops the rest', () {
      final sink = FileLogSink(dir.path, maxLinesPerRun: 5);
      for (var i = 0; i < 10; i++) {
        sink.write('line $i');
      }
      sink.close();
      final written = lines();
      expect(written.length, 6, reason: '5 lines plus one warning');
      expect(written.take(5), [
        'line 0',
        'line 1',
        'line 2',
        'line 3',
        'line 4',
      ]);
      expect(written[5], contains('cap reached'));
    });
  });

  group('rotation', () {
    test('an oversized log rotates once at startup to main.log.1', () {
      final log = File(p.join(dir.path, 'main.log'))
        ..writeAsStringSync('old run\n' * 100);
      final sink = FileLogSink(dir.path, maxFileBytes: 100);
      sink.write('new run');
      sink.close();
      expect(File('${log.path}.1').readAsLinesSync().first, 'old run');
      expect(lines(), [
        'new run',
      ], reason: 'the fresh file holds only the new run');
    });

    test('a small log is not rotated', () {
      File(p.join(dir.path, 'main.log')).writeAsStringSync('previous run\n');
      final sink = FileLogSink(dir.path)..write('appended');
      sink.close();
      expect(File(p.join(dir.path, 'main.log.1')).existsSync(), isFalse);
      expect(lines(), ['previous run', 'appended']);
    });

    test('rotation replaces a stale main.log.1', () {
      File(p.join(dir.path, 'main.log')).writeAsStringSync('big new\n' * 50);
      File(p.join(dir.path, 'main.log.1')).writeAsStringSync('ancient\n');
      FileLogSink(dir.path, maxFileBytes: 10).close();
      expect(
        File(p.join(dir.path, 'main.log.1')).readAsLinesSync().first,
        'big new',
      );
    });
  });

  group('redaction', () {
    test('query strings never reach disk', () {
      final sink = FileLogSink(dir.path);
      sink.write(
        'fetching https://api.example.com/dl?token=SECRET&sig=ABC done',
      );
      sink.close();
      final line = lines().single;
      expect(line, contains('https://api.example.com/dl'));
      expect(line, isNot(contains('SECRET')));
      expect(line, isNot(contains('token=')));
      expect(line, endsWith('done'));
    });

    test('bearer tokens never reach disk', () {
      final sink = FileLogSink(dir.path);
      sink.write('header Authorization: Bearer abc.DEF-123_x sent');
      sink.close();
      final line = lines().single;
      expect(line, contains('Bearer [redacted]'));
      expect(line, isNot(contains('abc.DEF')));
    });

    test('the helper is usable on its own', () {
      expect(
        FileLogSink.redact('GET https://x.test/a?k=v and Bearer tok'),
        'GET https://x.test/a and Bearer [redacted]',
      );
    });
  });

  test('reset truncates in place — same file, empty, budget restarted', () {
    final sink = FileLogSink(dir.path, maxLinesPerRun: 2);
    sink.write('one');
    sink.write('two');
    sink.write('dropped');
    sink.reset();
    sink.write('after reset');
    sink.close();
    expect(lines(), ['after reset']);
  });

  test('export copies the log out as zeroshiru-<epoch>.log', () {
    final out = Directory(p.join(dir.path, 'exports'))..createSync();
    final sink = FileLogSink(dir.path)..write('evidence');
    final exported = sink.export(out.path);
    sink.close();
    expect(p.basename(exported.path), matches(RegExp(r'^zeroshiru-\d+\.log$')));
    expect(exported.readAsLinesSync(), ['evidence']);
    expect(lines(), ['evidence'], reason: 'the original is untouched');
  });

  test('clamp counts bytes, not characters', () {
    final sink = FileLogSink(dir.path);
    final clamped = sink.clamp('€' * 1000); // 3000 bytes
    sink.close();
    expect(utf8.encode(clamped.split(' …')[0]).length, lessThanOrEqualTo(2000));
  });
}
