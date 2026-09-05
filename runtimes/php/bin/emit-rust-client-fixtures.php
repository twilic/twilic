#!/usr/bin/env php
<?php

declare(strict_types=1);

require dirname(__DIR__) . '/vendor/autoload.php';

use Twilic\InteropFixtures;

try {
    fwrite(STDOUT, InteropFixtures::emitInteropFixtures());
} catch (Throwable $err) {
    fwrite(STDERR, 'emit fixtures: ' . $err->getMessage() . PHP_EOL);
    exit(1);
}
