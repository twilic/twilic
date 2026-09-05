import 'dart:io';

import 'package:twilic/twilic.dart';

void main() {
  try {
    // ignore: avoid_print
    print(emitInteropFixtures());
  } catch (e, st) {
    // ignore: avoid_print
    print('emit fixtures: $e\n$st');
    // ignore: avoid_exit
    exitCode = 1;
  }
}
