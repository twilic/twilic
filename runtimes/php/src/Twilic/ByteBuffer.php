<?php

declare(strict_types=1);

namespace Twilic;

/** Growable binary buffer (Python bytearray equivalent). */
final class ByteBuffer
{
    private string $data = '';

    public function append(int $byte): void
    {
        $this->data .= chr($byte & 0xFF);
    }

    public function appendBytes(string $bytes): void
    {
        $this->data .= $bytes;
    }

    public function bytes(): string
    {
        return $this->data;
    }

    public function length(): int
    {
        return strlen($this->data);
    }
}
