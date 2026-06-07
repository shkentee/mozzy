import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:mocktail/mocktail.dart';
import 'package:mojio/pages/drive_files_page.dart';
import 'package:mojio/services/wr_drive_uploader.dart';

class _MockUploader extends Mock implements WrDriveUploader {}

void main() {
  late _MockUploader mockUploader;

  setUp(() {
    mockUploader = _MockUploader();
  });

  Widget hostedPage() =>
      MaterialApp(home: DriveFilesPage(uploader: mockUploader));

  testWidgets('shows loading indicator while listFiles() is pending',
      (tester) async {
    final completer = Completer<List<drive.File>>();
    when(() => mockUploader.listFiles()).thenAnswer((_) => completer.future);

    await tester.pumpWidget(hostedPage());
    // Future not yet resolved — spinner must be visible.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // Resolve so tearDown does not warn about pending timers.
    completer.complete([]);
    await tester.pumpAndSettle();
  });

  testWidgets('shows empty-state text when listFiles() returns []',
      (tester) async {
    when(() => mockUploader.listFiles()).thenAnswer((_) async => []);

    await tester.pumpWidget(hostedPage());
    await tester.pumpAndSettle();

    expect(find.text('No recordings uploaded yet.'), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets('shows file name in list when listFiles() returns files',
      (tester) async {
    final file = drive.File()
      ..id = 'f1'
      ..name = 'session-001.opus';
    when(() => mockUploader.listFiles()).thenAnswer((_) async => [file]);

    await tester.pumpWidget(hostedPage());
    await tester.pumpAndSettle();

    expect(find.text('session-001.opus'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
  });

  testWidgets('tapping delete calls deleteFile() and removes the tile',
      (tester) async {
    final file = drive.File()
      ..id = 'f1'
      ..name = 'to-delete.opus';
    when(() => mockUploader.listFiles()).thenAnswer((_) async => [file]);
    when(() => mockUploader.deleteFile(any())).thenAnswer((_) async {});

    await tester.pumpWidget(hostedPage());
    await tester.pumpAndSettle();

    expect(find.text('to-delete.opus'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    verify(() => mockUploader.deleteFile('f1')).called(1);
    expect(find.text('to-delete.opus'), findsNothing);
  });

  testWidgets('shows error text when listFiles() throws', (tester) async {
    when(() => mockUploader.listFiles())
        .thenAnswer((_) async => throw Exception('network error'));

    await tester.pumpWidget(hostedPage());
    await tester.pumpAndSettle();

    expect(find.textContaining('Error:'), findsOneWidget);
    expect(find.textContaining('network error'), findsOneWidget);
  });
}
