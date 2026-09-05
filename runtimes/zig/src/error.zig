pub const TwilicError = error{
    UnexpectedEof,
    InvalidKind,
    InvalidTag,
    InvalidData,
    Utf8Error,
    UnknownReference,
    StatelessRetryRequired,
    UnsupportedKind,
};

pub const Result = TwilicError;
