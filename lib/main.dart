import 'package:flutter/material.dart';
import 'presentation_receiver_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized(); // ✅ обязательно для path_provider
  runApp(const RoboShareProjectorApp());
}

class RoboShareProjectorApp extends StatelessWidget {
  const RoboShareProjectorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'RoboShare Projector',
      theme: ThemeData(
        primarySwatch: Colors.orange,
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const PresentationReceiverPage(),
    );
  }
}
