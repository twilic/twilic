namespace Twilic.Core;

public enum MessageKind : byte
{
    Scalar = 0x00,
    Array = 0x01,
    Map = 0x02,
    ShapedObject = 0x03,
    SchemaObject = 0x04,
    TypedVector = 0x05,
    RowBatch = 0x06,
    ColumnBatch = 0x07,
    Control = 0x08,
    Ext = 0x09,
    StatePatch = 0x0A,
    TemplateBatch = 0x0B,
    ControlStream = 0x0C,
    BaseSnapshot = 0x0D,
}

public enum ValueKind
{
    Null,
    Bool,
    I64,
    U64,
    F64,
    String,
    Binary,
    Array,
    Map,
}

public enum StringMode
{
    Empty,
    Literal,
    Ref,
    PrefixDelta,
    InlineEnum,
}

public enum ElementType
{
    Bool,
    I64,
    U64,
    F64,
    String,
    Binary,
    Value,
}

public enum VectorCodec
{
    Plain,
    DirectBitpack,
    DeltaBitpack,
    ForBitpack,
    DeltaForBitpack,
    DeltaDeltaBitpack,
    Rle,
    PatchedFor,
    Simple8B,
    XorFloat,
    Dictionary,
    StringRef,
    PrefixDelta,
}

public enum NullStrategy
{
    None,
    PresenceBitmap,
    InvertedPresenceBitmap,
    AllPresentElided,
}

public enum ControlOpcode
{
    RegisterKeys,
    RegisterShape,
    RegisterStrings,
    PromoteStringFieldToEnum,
    ResetTables,
    ResetState,
}

public enum PatchOpcode
{
    Keep,
    ReplaceScalar,
    ReplaceVector,
    AppendVector,
    TruncateVector,
    DeleteField,
    InsertField,
    StringRef,
    PrefixDelta,
}

public enum ControlStreamCodec
{
    Plain,
    Rle,
    Bitpack,
    Huffman,
    Fse,
}

public enum UnknownReferencePolicy
{
    FailFast,
    StatelessRetry,
}

public enum DictionaryFallback
{
    FailFast,
    StatelessRetry,
}

internal static class KindParsing
{
    internal static bool MessageKindFromByte(byte b, out MessageKind kind)
    {
        if (Enum.IsDefined(typeof(MessageKind), (MessageKind)b))
        {
            kind = (MessageKind)b;
            return true;
        }
        kind = MessageKind.Scalar;
        return false;
    }

    internal static bool StringModeFromByte(byte b, out StringMode mode)
    {
        if (b <= 4)
        {
            mode = (StringMode)b;
            return true;
        }
        mode = StringMode.Empty;
        return false;
    }

    internal static bool ElementTypeFromByte(byte b, out ElementType t)
    {
        if (b <= 6)
        {
            t = (ElementType)b;
            return true;
        }
        t = ElementType.Bool;
        return false;
    }

    internal static bool VectorCodecFromByte(byte b, out VectorCodec codec)
    {
        if (b <= 12)
        {
            codec = (VectorCodec)b;
            return true;
        }
        codec = VectorCodec.Plain;
        return false;
    }

    internal static bool NullStrategyFromByte(byte b, out NullStrategy s)
    {
        if (b <= 3)
        {
            s = (NullStrategy)b;
            return true;
        }
        s = NullStrategy.None;
        return false;
    }

    internal static bool ControlOpcodeFromByte(byte b, out ControlOpcode op)
    {
        if (b <= 5)
        {
            op = (ControlOpcode)b;
            return true;
        }
        op = ControlOpcode.RegisterKeys;
        return false;
    }

    internal static bool PatchOpcodeFromByte(byte b, out PatchOpcode op)
    {
        if (b <= 8)
        {
            op = (PatchOpcode)b;
            return true;
        }
        op = PatchOpcode.Keep;
        return false;
    }

    internal static bool ControlStreamCodecFromByte(byte b, out ControlStreamCodec codec)
    {
        if (b <= 4)
        {
            codec = (ControlStreamCodec)b;
            return true;
        }
        codec = ControlStreamCodec.Plain;
        return false;
    }

    internal static bool DictionaryFallbackFromByte(byte b, out DictionaryFallback fb)
    {
        if (b == 0)
        {
            fb = DictionaryFallback.FailFast;
            return true;
        }
        if (b == 1)
        {
            fb = DictionaryFallback.StatelessRetry;
            return true;
        }
        fb = DictionaryFallback.FailFast;
        return false;
    }
}
