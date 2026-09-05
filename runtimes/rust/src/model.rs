use std::collections::BTreeMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum MessageKind {
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
    SchemaBatch = 0x0E,
    BoundStream = 0x0F,
}

impl MessageKind {
    pub fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0x00 => Some(Self::Scalar),
            0x01 => Some(Self::Array),
            0x02 => Some(Self::Map),
            0x03 => Some(Self::ShapedObject),
            0x04 => Some(Self::SchemaObject),
            0x05 => Some(Self::TypedVector),
            0x06 => Some(Self::RowBatch),
            0x07 => Some(Self::ColumnBatch),
            0x08 => Some(Self::Control),
            0x09 => Some(Self::Ext),
            0x0A => Some(Self::StatePatch),
            0x0B => Some(Self::TemplateBatch),
            0x0C => Some(Self::ControlStream),
            0x0D => Some(Self::BaseSnapshot),
            0x0E => Some(Self::SchemaBatch),
            0x0F => Some(Self::BoundStream),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    I64(i64),
    U64(u64),
    F64(f64),
    String(String),
    Binary(Vec<u8>),
    Array(Vec<Value>),
    Map(Vec<(String, Value)>),
}

impl Value {
    pub fn is_scalar(&self) -> bool {
        !matches!(self, Self::Array(_) | Self::Map(_))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeyRef {
    Literal(String),
    Id(u64),
}

#[derive(Debug, Clone, PartialEq)]
pub struct MapEntry {
    pub key: KeyRef,
    pub value: Value,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum StringMode {
    Empty = 0,
    Literal = 1,
    Ref = 2,
    PrefixDelta = 3,
    InlineEnum = 4,
}

impl StringMode {
    pub fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Empty),
            1 => Some(Self::Literal),
            2 => Some(Self::Ref),
            3 => Some(Self::PrefixDelta),
            4 => Some(Self::InlineEnum),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct StringValue {
    pub mode: StringMode,
    pub value: String,
    pub ref_id: Option<u64>,
    pub prefix_len: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ElementType {
    Bool = 0,
    I64 = 1,
    U64 = 2,
    F64 = 3,
    String = 4,
    Binary = 5,
    Value = 6,
}

impl ElementType {
    pub fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Bool),
            1 => Some(Self::I64),
            2 => Some(Self::U64),
            3 => Some(Self::F64),
            4 => Some(Self::String),
            5 => Some(Self::Binary),
            6 => Some(Self::Value),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum VectorCodec {
    Plain = 0,
    DirectBitpack = 1,
    DeltaBitpack = 2,
    ForBitpack = 3,
    DeltaForBitpack = 4,
    DeltaDeltaBitpack = 5,
    Rle = 6,
    PatchedFor = 7,
    Simple8b = 8,
    XorFloat = 9,
    Dictionary = 10,
    StringRef = 11,
    PrefixDelta = 12,
}

impl VectorCodec {
    pub fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Plain),
            1 => Some(Self::DirectBitpack),
            2 => Some(Self::DeltaBitpack),
            3 => Some(Self::ForBitpack),
            4 => Some(Self::DeltaForBitpack),
            5 => Some(Self::DeltaDeltaBitpack),
            6 => Some(Self::Rle),
            7 => Some(Self::PatchedFor),
            8 => Some(Self::Simple8b),
            9 => Some(Self::XorFloat),
            10 => Some(Self::Dictionary),
            11 => Some(Self::StringRef),
            12 => Some(Self::PrefixDelta),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum TypedVectorData {
    Bool(Vec<bool>),
    I64(Vec<i64>),
    U64(Vec<u64>),
    F64(Vec<f64>),
    String(Vec<String>),
    Binary(Vec<Vec<u8>>),
    Value(Vec<Value>),
}

#[derive(Debug, Clone, PartialEq)]
pub struct TypedVector {
    pub element_type: ElementType,
    pub codec: VectorCodec,
    pub data: TypedVectorData,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SchemaField {
    pub number: u64,
    pub name: String,
    pub logical_type: String,
    pub required: bool,
    pub default_value: Option<Value>,
    pub min: Option<i64>,
    pub max: Option<i64>,
    pub enum_values: Vec<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Schema {
    pub schema_id: u64,
    pub name: String,
    pub fields: Vec<SchemaField>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum NullStrategy {
    None = 0,
    PresenceBitmap = 1,
    InvertedPresenceBitmap = 2,
    AllPresentElided = 3,
}

impl NullStrategy {
    pub fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::None),
            1 => Some(Self::PresenceBitmap),
            2 => Some(Self::InvertedPresenceBitmap),
            3 => Some(Self::AllPresentElided),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Column {
    pub field_id: u64,
    pub null_strategy: NullStrategy,
    pub presence: Option<Vec<bool>>,
    pub codec: VectorCodec,
    pub dictionary_id: Option<u64>,
    pub values: TypedVectorData,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum PresenceStrategy {
    Normal = 0,
    Inverted = 1,
    AllPresent = 2,
}

impl PresenceStrategy {
    pub fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Normal),
            1 => Some(Self::Inverted),
            2 => Some(Self::AllPresent),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct BoundRecord {
    pub presence: Option<Vec<bool>>,
    pub fields: Vec<Value>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ControlOpcode {
    RegisterKeys = 0,
    RegisterShape = 1,
    RegisterStrings = 2,
    PromoteStringFieldToEnum = 3,
    ResetTables = 4,
    ResetState = 5,
}

impl ControlOpcode {
    pub fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::RegisterKeys),
            1 => Some(Self::RegisterShape),
            2 => Some(Self::RegisterStrings),
            3 => Some(Self::PromoteStringFieldToEnum),
            4 => Some(Self::ResetTables),
            5 => Some(Self::ResetState),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum ControlMessage {
    RegisterKeys(Vec<String>),
    RegisterShape {
        shape_id: u64,
        keys: Vec<KeyRef>,
    },
    RegisterStrings(Vec<String>),
    PromoteStringFieldToEnum {
        field_identity: String,
        values: Vec<String>,
    },
    ResetTables,
    ResetState,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum PatchOpcode {
    Keep = 0,
    ReplaceScalar = 1,
    ReplaceVector = 2,
    AppendVector = 3,
    TruncateVector = 4,
    DeleteField = 5,
    InsertField = 6,
    StringRef = 7,
    PrefixDelta = 8,
}

impl PatchOpcode {
    pub fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Keep),
            1 => Some(Self::ReplaceScalar),
            2 => Some(Self::ReplaceVector),
            3 => Some(Self::AppendVector),
            4 => Some(Self::TruncateVector),
            5 => Some(Self::DeleteField),
            6 => Some(Self::InsertField),
            7 => Some(Self::StringRef),
            8 => Some(Self::PrefixDelta),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum BaseRef {
    Previous,
    BaseId(u64),
}

#[derive(Debug, Clone, PartialEq)]
pub struct PatchOperation {
    pub field_id: u64,
    pub opcode: PatchOpcode,
    pub value: Option<Value>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ControlStreamCodec {
    Plain = 0,
    Rle = 1,
    Bitpack = 2,
    Huffman = 3,
    Fse = 4,
}

impl ControlStreamCodec {
    pub fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0 => Some(Self::Plain),
            1 => Some(Self::Rle),
            2 => Some(Self::Bitpack),
            3 => Some(Self::Huffman),
            4 => Some(Self::Fse),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Message {
    Scalar(Value),
    Array(Vec<Value>),
    Map(Vec<MapEntry>),
    ShapedObject {
        shape_id: u64,
        presence: Option<Vec<bool>>,
        values: Vec<Value>,
    },
    SchemaObject {
        schema_id: Option<u64>,
        presence: Option<Vec<bool>>,
        fields: Vec<Value>,
    },
    TypedVector(TypedVector),
    RowBatch {
        rows: Vec<Vec<Value>>,
    },
    ColumnBatch {
        count: u64,
        columns: Vec<Column>,
    },
    SchemaBatch {
        schema_id: u64,
        count: u64,
        columns: Vec<Column>,
    },
    BoundStream {
        schema_id: u64,
        presence_strategy: PresenceStrategy,
        records: Vec<BoundRecord>,
    },
    Control(ControlMessage),
    Ext {
        ext_type: u64,
        payload: Vec<u8>,
    },
    StatePatch {
        base_ref: BaseRef,
        operations: Vec<PatchOperation>,
        literals: Vec<Value>,
    },
    TemplateBatch {
        template_id: u64,
        count: u64,
        changed_column_mask: Vec<bool>,
        columns: Vec<Column>,
    },
    ControlStream {
        codec: ControlStreamCodec,
        payload: Vec<u8>,
    },
    BaseSnapshot {
        base_id: u64,
        schema_or_shape_ref: u64,
        payload: Box<Message>,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub struct TemplateDescriptor {
    pub template_id: u64,
    pub field_ids: Vec<u64>,
    pub null_strategies: Vec<NullStrategy>,
    pub codecs: Vec<VectorCodec>,
}

pub type MetadataMap = BTreeMap<String, String>;
