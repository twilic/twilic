#!/usr/bin/env php
<?php

declare(strict_types=1);

require dirname(__DIR__) . '/vendor/autoload.php';

use Twilic\InteropFixtures;

try {
    InteropFixtures::decodeRustServerInput(STDIN);
} catch (Throwable $err) {
    fwrite(STDERR, 'decode fixtures: ' . $err->getMessage() . PHP_EOL);
    exit(1);
}
