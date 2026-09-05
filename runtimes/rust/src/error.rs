use core::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TwilicError {
    UnexpectedEof,
    InvalidKind(u8),
    InvalidTag(u8),
    InvalidData(&'static str),
    Utf8Error,
    UnknownReference(&'static str, u64),
    StatelessRetryRequired(&'static str, u64),
}

impl fmt::Display for TwilicError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnexpectedEof => write!(f, "unexpected end of input"),
            Self::InvalidKind(k) => write!(f, "invalid message kind: {k:#04x}"),
            Self::InvalidTag(t) => write!(f, "invalid value tag: {t:#04x}"),
            Self::InvalidData(msg) => write!(f, "invalid data: {msg}"),
            Self::Utf8Error => write!(f, "utf8 decode error"),
            Self::UnknownReference(ty, id) => write!(f, "unknown reference: {ty}={id}"),
            Self::StatelessRetryRequired(ty, id) => {
                write!(f, "stateless retry required for reference: {ty}={id}")
            }
        }
    }
}

impl std::error::Error for TwilicError {}

pub type Result<T> = core::result::Result<T, TwilicError>;
