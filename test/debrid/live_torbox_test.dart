@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zero/domain/models/availability.dart';
import 'package:zero/domain/ports/debrid_client.dart';
import 'package:zero/infrastructure/debrid/debrid_client_impl.dart';
import 'package:zero/infrastructure/network/http_transport_impl.dart';

const _publicSampleHashes = [
  // WebTorrent's public-domain Sintel sample.
  '08ada5a7a6183aae1e09d831df6748d566095a10',
  // WebTorrent's public-domain Big Buck Bunny sample.
  'dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c',
];

void main() {
  final apiKey = Platform.environment['ZERO_LIVE_TORBOX_KEY']?.trim();

  test(
    'TorBox accepts the account and exposes read-only cached file metadata',
    () async {
      final transport = PackageHttpTransport();
      addTearDown(transport.close);
      final client = ProviderDebridClient(DebridService.torbox, transport);

      final account = await client.validate(apiKey!);
      expect(account.username.trim(), isNotEmpty);

      final availability = await client.availability(
        apiKey,
        _publicSampleHashes,
      );
      expect(availability.keys, containsAll(_publicSampleHashes));
      expect(
        availability.values,
        everyElement(anyOf(Availability.cached, Availability.available)),
      );

      final inspected = await client.inspectAvailability(
        apiKey,
        _publicSampleHashes,
      );
      expect(inspected.keys, containsAll(_publicSampleHashes));
      expect(
        inspected.values.map((detail) => detail.availability),
        everyElement(anyOf(Availability.cached, Availability.available)),
      );
      for (final detail in inspected.values) {
        if (detail.availability == Availability.cached) {
          expect(
            detail.files,
            isNotNull,
            reason: 'list_files=true should include cached member metadata',
          );
          expect(detail.files, isNotEmpty);
        }
      }
    },
    skip: apiKey == null || apiKey.isEmpty
        ? 'Set ZERO_LIVE_TORBOX_KEY to opt into live account testing.'
        : false,
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
