#nullable enable

namespace Twilic.Core;

public sealed class MessageMapEntry
{
    public KeyRef Key = KeyRef.LiteralRef("");
    public Value Value = Value.OfNull();
}

public sealed class TypedVectorData
{
    public List<bool> Bools = new();
    public List<long> I64S = new();
    public List<ulong> U64S = new();
    public List<double> F64S = new();
    public List<string> Strings = new();
    public List<byte[]> Binary = new();
    public List<Value> Values = new();
    public ElementType Kind = ElementType.Value;
}

public sealed class TypedVector
{
    public ElementType ElementType = ElementType.Value;
    public VectorCodec Codec = VectorCodec.Plain;
    public TypedVectorData Data = new();
}

public sealed class Column
{
    public ulong FieldId;
    public NullStrategy NullStrategy = NullStrategy.None;
    public List<bool> Presence = new();
    public bool HasPresence;
    public VectorCodec Codec = VectorCodec.Plain;
    public ulong? DictionaryId;
    public TypedVectorData Values = new();
}

public sealed class RegisterShapeControl
{
    public ulong ShapeId;
    public List<KeyRef> Keys = new();
}

public sealed class PromoteEnumControl
{
    public string FieldIdentity = "";
    public List<string> Values = new();
}

public sealed class ControlMessage
{
    public List<string> RegisterKeys = new();
    public RegisterShapeControl? RegisterShape;
    public List<string> RegisterStrings = new();
    public PromoteEnumControl? PromoteStringFieldToEnum;
    public bool ResetTables;
    public bool ResetState;
    public ControlOpcode Opcode = ControlOpcode.ResetTables;
}

public sealed class PatchOperation
{
    public ulong FieldId;
    public PatchOpcode Opcode = PatchOpcode.Keep;
    public Value? Value;
}

public sealed class ShapedObjectMessage
{
    public ulong ShapeId;
    public List<bool> Presence = new();
    public bool HasPresence;
    public List<Value> Values = new();
}

public sealed class SchemaObjectMessage
{
    public ulong? SchemaId;
    public List<bool> Presence = new();
    public bool HasPresence;
    public List<Value> Fields = new();
}

public sealed class RowBatchMessage
{
    public List<List<Value>> Rows = new();
}

public sealed class ColumnBatchMessage
{
    public ulong Count;
    public List<Column> Columns = new();
}

public sealed class ExtMessage
{
    public ulong ExtType;
    public byte[] Payload = Array.Empty<byte>();
}

public sealed class StatePatchMessage
{
    public BaseRef BaseRef = BaseRef.PreviousRef();
    public List<PatchOperation> Operations = new();
    public List<Value> Literals = new();
}

public sealed class TemplateBatchMessage
{
    public ulong TemplateId;
    public ulong Count;
    public List<bool> ChangedColumnMask = new();
    public List<Column> Columns = new();
}

public sealed class ControlStreamMessage
{
    public ControlStreamCodec Codec = ControlStreamCodec.Plain;
    public byte[] Payload = Array.Empty<byte>();
}

public sealed class BaseSnapshotMessage
{
    public ulong BaseId;
    public ulong SchemaOrShapeRef;
    public Message Payload = new();
}

internal sealed class TemplateDescriptor
{
    public ulong TemplateId { get; set; }
    public List<ulong> FieldIds = new();
    public List<NullStrategy> NullStrategies = new();
    public List<VectorCodec> Codecs = new();
}

public sealed class Message
{
    public MessageKind Kind = MessageKind.Scalar;
    public Value? Scalar;
    public List<Value> Array = new();
    public List<MessageMapEntry> Map = new();
    public ShapedObjectMessage? ShapedObject;
    public SchemaObjectMessage? SchemaObject;
    public TypedVector? TypedVector;
    public RowBatchMessage? RowBatch;
    public ColumnBatchMessage? ColumnBatch;
    public ControlMessage? Control;
    public ExtMessage? Ext;
    public StatePatchMessage? StatePatch;
    public TemplateBatchMessage? TemplateBatch;
    public ControlStreamMessage? ControlStream;
    public BaseSnapshotMessage? BaseSnapshot;
}

internal sealed class DictionaryProfile
{
    public ulong Version;
    public ulong Hash;
    public ulong ExpiresAt;
    public DictionaryFallback Fallback;

    public DictionaryProfile(ulong version, ulong hash, ulong expiresAt, DictionaryFallback fallback)
    {
        Version = version;
        Hash = hash;
        ExpiresAt = expiresAt;
        Fallback = fallback;
    }
}

internal sealed class InternTable
{
    internal readonly Dictionary<string, ulong> ByValue = new();
    internal readonly List<string> ById = new();

    internal ulong? GetId(string value) => ByValue.GetValueOrDefault(value);

    internal string? GetValue(ulong id) => id < (ulong)ById.Count ? ById[(int)id] : null;

    internal ulong Register(string value)
    {
        if (ByValue.TryGetValue(value, out var existing))
            return existing;
        ulong id = (ulong)ById.Count;
        ById.Add(value);
        ByValue[value] = id;
        return id;
    }

    internal void Clear()
    {
        ByValue.Clear();
        ById.Clear();
    }
}

internal sealed class ShapeTable
{
    internal readonly Dictionary<string, ulong> ByKeys = new();
    internal readonly Dictionary<ulong, List<string>> ById = new();
    internal readonly Dictionary<string, ulong> Observations = new();
    internal ulong NextId;
}

internal sealed class BaseSnapshotEntry
{
    public ulong Id;
    public Message Message = new();
}

public sealed class SessionOptions
{
    public int MaxBaseSnapshots = 8;
    public bool EnableStatePatch = true;
    public bool EnableTemplateBatch = true;
    public bool EnableTrainedDictionary = true;
    public UnknownReferencePolicy UnknownReferencePolicy = UnknownReferencePolicy.FailFast;
}

internal sealed class SessionState
{
    public SessionOptions Options = new();
    public InternTable KeyTable = new();
    public InternTable StringTable = new();
    public ShapeTable ShapeTable = new();
    public Dictionary<string, ulong> EncodeShapeObservations = new();
    public List<BaseSnapshotEntry> BaseSnapshots = new();
    public Dictionary<ulong, TemplateDescriptor> Templates = new();
    public Dictionary<ulong, List<Column>> TemplateColumns = new();
    public Dictionary<string, List<string>> FieldEnums = new();
    public Dictionary<ulong, byte[]> Dictionaries = new();
    public Dictionary<ulong, DictionaryProfile> DictionaryProfiles = new();
    public Dictionary<ulong, Schema> Schemas = new();
    public ulong? LastSchemaId;
    public Message? PreviousMessage;
    public int? PreviousMessageSize;
    public ulong NextBaseId;
    public ulong NextTemplateId;
    public ulong NextDictionaryId;
}

internal static class SessionCore
{
    internal static SessionOptions DefaultSessionOptions() => new();

    internal static string ShapeKey(IReadOnlyList<string> keys) => string.Join("\0", keys);

    internal static void RegisterBaseSnapshot(SessionState state, ulong baseId, Message message)
    {
        state.BaseSnapshots.RemoveAll(e => e.Id == baseId);
        state.BaseSnapshots.Add(new BaseSnapshotEntry { Id = baseId, Message = message }); // TODO: deep clone when protocol helpers land
        while (state.BaseSnapshots.Count > state.Options.MaxBaseSnapshots)
            state.BaseSnapshots.RemoveAt(0);
    }

    internal static ulong AllocateBaseId(SessionState state) => state.NextBaseId++;

    internal static ulong AllocateTemplateId(SessionState state) => state.NextTemplateId++;

    internal static ulong AllocateDictionaryId(SessionState state) => state.NextDictionaryId++;

    internal static Message? GetBaseSnapshot(SessionState state, ulong baseId)
    {
        foreach (var entry in state.BaseSnapshots)
            if (entry.Id == baseId)
                return entry.Message;
        return null;
    }

    internal static void ResetTables(SessionState state)
    {
        state.KeyTable.Clear();
        state.StringTable.Clear();
        state.ShapeTable.ByKeys.Clear();
        state.ShapeTable.ById.Clear();
        state.ShapeTable.Observations.Clear();
        state.ShapeTable.NextId = 0;
        state.EncodeShapeObservations.Clear();
        state.FieldEnums.Clear();
    }

    internal static void ResetState(SessionState state)
    {
        ResetTables(state);
        state.BaseSnapshots.Clear();
        state.Templates.Clear();
        state.TemplateColumns.Clear();
        state.Dictionaries.Clear();
        state.DictionaryProfiles.Clear();
        state.Schemas.Clear();
        state.LastSchemaId = null;
        state.PreviousMessage = null;
        state.PreviousMessageSize = null;
        state.NextBaseId = 0;
        state.NextTemplateId = 0;
        state.NextDictionaryId = 0;
    }
}
