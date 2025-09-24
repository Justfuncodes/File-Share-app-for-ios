// This is a basic Flutter widget test.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// IMPORTANT: This line assumes your folder name is flutter_application_1.
// If you rename the folder, you might need to change this line.
import 'package:file_share_app/main.dart';

void main() {
  testWidgets('App displays initial UI correctly', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const FileShareApp());

    // Verify that the main title "File Share" is visible.
    expect(find.text('File Share'), findsOneWidget);

    // Verify that the "Send" button is visible.
    expect(find.text('Send'), findsOneWidget);

    // Verify that the "Receive" button is visible.
    expect(find.text('Receive'), findsOneWidget);

    // Verify that the old counter text is NOT present.
    expect(find.text('0'), findsNothing);
    expect(find.text('1'), findsNothing);
  });
}
