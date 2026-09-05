import 'dart:convert';
import 'dart:io';

import 'package:twilic/twilic.dart';

Future<void> main() async {
  try {
    final text = await stdin.transform(utf8.decoder).join();
    decodeRustServerFrames(text);
  } catch (e, st) {
    // ignore: avoid_print
    print('decode fixtures: $e\n$st');
    // ignore: avoid_exit
    exitCode = 1;
  }
}
