<?php

declare(strict_types=1);

namespace Twilic;

enum UnknownReferencePolicy: int
{
    case FAIL_FAST = 0;
    case STATELESS_RETRY = 1;
}

const UnknownReferencePolicyFailFast = UnknownReferencePolicy::FAIL_FAST;
const UnknownReferencePolicyStatelessRetry = UnknownReferencePolicy::STATELESS_RETRY;

enum DictionaryFallback: int
{
    case FAIL_FAST = 0;
    case STATELESS_RETRY = 1;
}

const DictionaryFallbackFailFast = DictionaryFallback::FAIL_FAST;
const DictionaryFallbackStatelessRetry = DictionaryFallback::STATELESS_RETRY;

/** @return array{0: DictionaryFallback, 1: bool} */
function dictionary_fallback_from_byte(int $b): array
{
    if ($b === 0) {
        return [DictionaryFallback::FAIL_FAST, true];
    }
    if ($b === 1) {
        return [DictionaryFallback::STATELESS_RETRY, true];
    }
    return [DictionaryFallback::FAIL_FAST, false];
}

final class DictionaryProfile
{
    public function __construct(
        public int $version,
        public int $hash,
        public int $expiresAt,
        public DictionaryFallback $fallback,
    ) {
    }
}

final class SessionOptions
{
    public function __construct(
        public int $maxBaseSnapshots = 8,
        public bool $enableStatePatch = true,
        public bool $enableTemplateBatch = true,
        public bool $enableTrainedDictionary = true,
        public UnknownReferencePolicy $unknownReferencePolicy = UnknownReferencePolicy::FAIL_FAST,
    ) {
    }
}

function default_session_options(): SessionOptions
{
    return new SessionOptions();
}

final class InternTable
{
    /** @var array<string, int> */
    public array $byValue = [];
    /** @var list<string> */
    public array $byId = [];

    /** @return array{0: int, 1: bool} */
    public function getId(string $value): array
    {
        if (array_key_exists($value, $this->byValue)) {
            return [$this->byValue[$value], true];
        }
        return [0, false];
    }

    /** @return array{0: string, 1: bool} */
    public function getValue(int $refId): array
    {
        if ($refId >= count($this->byId)) {
            return ['', false];
        }
        return [$this->byId[$refId], true];
    }

    public function register(string $value): int
    {
        if (array_key_exists($value, $this->byValue)) {
            return $this->byValue[$value];
        }
        $refId = count($this->byId);
        $this->byId[] = $value;
        $this->byValue[$value] = $refId;
        return $refId;
    }

    public function clear(): void
    {
        $this->byValue = [];
        $this->byId = [];
    }
}

function shape_key(array $keys): string
{
    return implode("\0", $keys);
}

final class ShapeTable
{
    /** @var array<string, int> */
    public array $byKeys = [];
    /** @var array<int, list<string>> */
    public array $byId = [];
    /** @var array<string, int> */
    public array $observations = [];
    public int $nextId = 0;

    /** @param list<string> $keys */
    /** @return array{0: int, 1: bool} */
    public function getId(array $keys): array
    {
        $sk = shape_key($keys);
        if (array_key_exists($sk, $this->byKeys)) {
            return [$this->byKeys[$sk], true];
        }
        return [0, false];
    }

    /** @return array{0: ?list<string>, 1: bool} */
    public function getKeys(int $refId): array
    {
        if (!array_key_exists($refId, $this->byId)) {
            return [null, false];
        }
        return [$this->byId[$refId], true];
    }

    /** @param list<string> $keys */
    public function register(array $keys): int
    {
        $sk = shape_key($keys);
        if (array_key_exists($sk, $this->byKeys)) {
            return $this->byKeys[$sk];
        }
        $refId = $this->nextId;
        $this->nextId++;
        $this->byId[$refId] = $keys;
        $this->byKeys[$sk] = $refId;
        return $refId;
    }

    /** @param list<string> $keys */
    public function registerWithId(int $shapeId, array $keys): bool
    {
        $sk = shape_key($keys);
        if (array_key_exists($shapeId, $this->byId)) {
            return shape_key($this->byId[$shapeId]) === $sk;
        }
        if (array_key_exists($sk, $this->byKeys) && $this->byKeys[$sk] !== $shapeId) {
            return false;
        }
        $this->byId[$shapeId] = $keys;
        $this->byKeys[$sk] = $shapeId;
        if ($shapeId + 1 > $this->nextId) {
            $this->nextId = $shapeId + 1;
        }
        return true;
    }

    /** @param list<string> $keys */
    public function observe(array $keys): int
    {
        $sk = shape_key($keys);
        $this->observations[$sk] = ($this->observations[$sk] ?? 0) + 1;
        return $this->observations[$sk];
    }

    public function clear(): void
    {
        $this->byKeys = [];
        $this->byId = [];
        $this->observations = [];
        $this->nextId = 0;
    }
}

final class BaseSnapshotEntry
{
    public function __construct(
        public int $id,
        public Message $message,
    ) {
    }
}

final class SessionState
{
    public SessionOptions $options;
    public InternTable $keyTable;
    public InternTable $stringTable;
    public ShapeTable $shapeTable;
    /** @var array<string, int> */
    public array $encodeShapeObservations = [];
    /** @var list<BaseSnapshotEntry> */
    public array $baseSnapshots = [];
    /** @var array<int, TemplateDescriptor> */
    public array $templates = [];
    /** @var array<int, list<Column>> */
    public array $templateColumns = [];
    /** @var array<string, list<string>> */
    public array $fieldEnums = [];
    /** @var array<int, string> */
    public array $dictionaries = [];
    /** @var array<int, DictionaryProfile> */
    public array $dictionaryProfiles = [];
    /** @var array<int, Schema> */
    public array $schemas = [];
    public ?int $lastSchemaId = null;
    public ?Message $previousMessage = null;
    public ?int $previousMessageSize = null;
    public int $nextBaseId = 0;
    public int $nextTemplateId = 0;
    public int $nextDictionaryId = 0;

    public function __construct(?SessionOptions $options = null)
    {
        $this->options = $options ?? default_session_options();
        $this->keyTable = new InternTable();
        $this->stringTable = new InternTable();
        $this->shapeTable = new ShapeTable();
    }
}

function new_session_state(): SessionState
{
    return new SessionState();
}

function new_session_state_with_options(SessionOptions $options): SessionState
{
    return new SessionState($options);
}

function register_base_snapshot(SessionState $state, int $baseId, Message $message): void
{
    $filtered = array_values(array_filter(
        $state->baseSnapshots,
        static fn (BaseSnapshotEntry $e) => $e->id !== $baseId,
    ));
    $filtered[] = new BaseSnapshotEntry($baseId, $message->clone());
    while (count($filtered) > $state->options->maxBaseSnapshots) {
        array_shift($filtered);
    }
    $state->baseSnapshots = $filtered;
}

function allocate_base_id(SessionState $state): int
{
    $refId = $state->nextBaseId;
    $state->nextBaseId++;
    return $refId;
}

function allocate_template_id(SessionState $state): int
{
    $refId = $state->nextTemplateId;
    $state->nextTemplateId++;
    return $refId;
}

function allocate_dictionary_id(SessionState $state): int
{
    $refId = $state->nextDictionaryId;
    $state->nextDictionaryId++;
    return $refId;
}

/** @return array{0: ?Message, 1: bool} */
function get_base_snapshot(SessionState $state, int $baseId): array
{
    foreach ($state->baseSnapshots as $entry) {
        if ($entry->id === $baseId) {
            return [$entry->message->clone(), true];
        }
    }
    return [null, false];
}

function reset_tables(SessionState $state): void
{
    $state->keyTable->clear();
    $state->stringTable->clear();
    $state->shapeTable->clear();
    $state->encodeShapeObservations = [];
    $state->fieldEnums = [];
}

function reset_state(SessionState $state): void
{
    reset_tables($state);
    $state->baseSnapshots = [];
    $state->templates = [];
    $state->templateColumns = [];
    $state->dictionaries = [];
    $state->dictionaryProfiles = [];
    $state->schemas = [];
    $state->lastSchemaId = null;
    $state->previousMessage = null;
    $state->previousMessageSize = null;
    $state->nextBaseId = 0;
    $state->nextTemplateId = 0;
    $state->nextDictionaryId = 0;
}
