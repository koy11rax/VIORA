import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viora_client/data/subscription_import.dart';
import 'package:viora_client/features/client/import_dialog.dart';

void main() {
  testWidgets(
    'multi-server paste previews real protocols and imports the full list',
    (tester) async {
      ImportedConnection? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<ImportedConnection>(
                    context: context,
                    builder: (_) => const ImportDialog(),
                  );
                },
                child: const Text('Открыть'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'hy2://fixture@example.org:443?sni=example.org#QUIC\n'
        'trojan://fixture@example.org:443?sni=example.org#TLS',
      );
      await tester.pumpAndSettle();
      expect(find.text('Hysteria2 · QUIC · TLS'), findsOneWidget);
      expect(find.text('Серверов: 2'), findsOneWidget);
      await tester.ensureVisible(find.text('Добавить подключение'));
      await tester.tap(find.text('Добавить подключение'));
      await tester.pumpAndSettle();
      expect(result!.profiles.map((p) => p.protocol), ['hysteria2', 'trojan']);
    },
  );
}
