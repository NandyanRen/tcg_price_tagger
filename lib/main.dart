import 'package:flutter/material.dart';

import 'settings.dart';
import 'ui/editor_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  runApp(TcgPriceTaggerApp(settings: settings));
}

class TcgPriceTaggerApp extends StatelessWidget {
  const TcgPriceTaggerApp({super.key, required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TCG Price Tagger',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.red,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: EditorPage(settings: settings),
    );
  }
}
