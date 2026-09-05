# MessageKind
MessageKindSCALAR <- 0x00L
MessageKindARRAY <- 0x01L
MessageKindMAP <- 0x02L
MessageKindSHAPED_OBJECT <- 0x03L
MessageKindSCHEMA_OBJECT <- 0x04L
MessageKindTYPED_VECTOR <- 0x05L
MessageKindROW_BATCH <- 0x06L
MessageKindCOLUMN_BATCH <- 0x07L
MessageKindCONTROL <- 0x08L
MessageKindEXT <- 0x09L
MessageKindSTATE_PATCH <- 0x0AL
MessageKindTEMPLATE_BATCH <- 0x0BL
MessageKindCONTROL_STREAM <- 0x0CL
MessageKindBASE_SNAPSHOT <- 0x0DL

# ValueKind
ValueKindNULL <- 0L
ValueKindBOOL <- 1L
ValueKindI64 <- 2L
ValueKindU64 <- 3L
ValueKindF64 <- 4L
ValueKindSTRING <- 5L
ValueKindBINARY <- 6L
ValueKindARRAY <- 7L
ValueKindMAP <- 8L

# StringMode
StringModeEMPTY <- 0L
StringModeLITERAL <- 1L
StringModeREF <- 2L
StringModePREFIX_DELTA <- 3L
StringModeINLINE_ENUM <- 4L

# ElementType
ElementTypeBOOL <- 0L
ElementTypeI64 <- 1L
ElementTypeU64 <- 2L
ElementTypeF64 <- 3L
ElementTypeSTRING <- 4L
ElementTypeBINARY <- 5L
ElementTypeVALUE <- 6L

# VectorCodec
VectorCodecPLAIN <- 0L
VectorCodecDIRECT_BITPACK <- 1L
VectorCodecDELTA_BITPACK <- 2L
VectorCodecFOR_BITPACK <- 3L
VectorCodecDELTA_FOR_BITPACK <- 4L
VectorCodecDELTA_DELTA_BITPACK <- 5L
VectorCodecRLE <- 6L
VectorCodecPATCHED_FOR <- 7L
VectorCodecSIMPLE8B <- 8L
VectorCodecXOR_FLOAT <- 9L
VectorCodecDICTIONARY <- 10L
VectorCodecSTRING_REF <- 11L
VectorCodecPREFIX_DELTA <- 12L

# NullStrategy
NullStrategyNONE <- 0L
NullStrategyPRESENCE_BITMAP <- 1L
NullStrategyINVERTED_PRESENCE_BITMAP <- 2L
NullStrategyALL_PRESENT_ELIDED <- 3L

# ControlOpcode
ControlOpcodeREGISTER_KEYS <- 0L
ControlOpcodeREGISTER_SHAPE <- 1L
ControlOpcodeREGISTER_STRINGS <- 2L
ControlOpcodePROMOTE_STRING_FIELD_TO_ENUM <- 3L
ControlOpcodeRESET_TABLES <- 4L
ControlOpcodeRESET_STATE <- 5L

# PatchOpcode
PatchOpcodeKEEP <- 0L
PatchOpcodeREPLACE_SCALAR <- 1L
PatchOpcodeREPLACE_VECTOR <- 2L
PatchOpcodeAPPEND_VECTOR <- 3L
PatchOpcodeTRUNCATE_VECTOR <- 4L
PatchOpcodeDELETE_FIELD <- 5L
PatchOpcodeINSERT_FIELD <- 6L
PatchOpcodeSTRING_REF <- 7L
PatchOpcodePREFIX_DELTA <- 8L

# ControlStreamCodec
ControlStreamCodecPLAIN <- 0L
ControlStreamCodecRLE <- 1L
ControlStreamCodecBITPACK <- 2L
ControlStreamCodecHUFFMAN <- 3L
ControlStreamCodecFSE <- 4L

MessageKindScalar <- MessageKindSCALAR
MessageKindArray <- MessageKindARRAY
MessageKindMap <- MessageKindMAP
MessageKindShapedObject <- MessageKindSHAPED_OBJECT
MessageKindSchemaObject <- MessageKindSCHEMA_OBJECT
MessageKindTypedVector <- MessageKindTYPED_VECTOR
MessageKindRowBatch <- MessageKindROW_BATCH
MessageKindColumnBatch <- MessageKindCOLUMN_BATCH
MessageKindControl <- MessageKindCONTROL
MessageKindExt <- MessageKindEXT
MessageKindStatePatch <- MessageKindSTATE_PATCH
MessageKindTemplateBatch <- MessageKindTEMPLATE_BATCH
MessageKindControlStream <- MessageKindCONTROL_STREAM
MessageKindBaseSnapshot <- MessageKindBASE_SNAPSHOT
ValueNull <- ValueKindNULL
ValueBool <- ValueKindBOOL
ValueI64 <- ValueKindI64
ValueU64 <- ValueKindU64
ValueF64 <- ValueKindF64
ValueString <- ValueKindSTRING
ValueBinary <- ValueKindBINARY
ValueArray <- ValueKindARRAY
ValueMap <- ValueKindMAP
StringModeEmpty <- StringModeEMPTY
StringModeLiteral <- StringModeLITERAL
StringModeRef <- StringModeREF
StringModePrefixDelta <- StringModePREFIX_DELTA
StringModeInlineEnum <- StringModeINLINE_ENUM
ElementTypeBool <- ElementTypeBOOL
ElementTypeI64 <- ElementTypeI64
ElementTypeU64 <- ElementTypeU64
ElementTypeF64 <- ElementTypeF64
ElementTypeString <- ElementTypeSTRING
ElementTypeBinary <- ElementTypeBINARY
ElementTypeValue <- ElementTypeVALUE
VectorCodecPlain <- VectorCodecPLAIN
VectorCodecDirectBitpack <- VectorCodecDIRECT_BITPACK
VectorCodecDeltaBitpack <- VectorCodecDELTA_BITPACK
VectorCodecForBitpack <- VectorCodecFOR_BITPACK
VectorCodecDeltaForBitpack <- VectorCodecDELTA_FOR_BITPACK
VectorCodecDeltaDeltaBitpack <- VectorCodecDELTA_DELTA_BITPACK
VectorCodecRle <- VectorCodecRLE
VectorCodecPatchedFor <- VectorCodecPATCHED_FOR
VectorCodecSimple8b <- VectorCodecSIMPLE8B
VectorCodecXorFloat <- VectorCodecXOR_FLOAT
VectorCodecDictionary <- VectorCodecDICTIONARY
VectorCodecStringRef <- VectorCodecSTRING_REF
VectorCodecPrefixDelta <- VectorCodecPREFIX_DELTA
NullStrategyNone <- NullStrategyNONE
NullStrategyPresenceBitmap <- NullStrategyPRESENCE_BITMAP
NullStrategyInvertedPresenceBitmap <- NullStrategyINVERTED_PRESENCE_BITMAP
NullStrategyAllPresentElided <- NullStrategyALL_PRESENT_ELIDED
ControlOpcodeRegisterKeys <- ControlOpcodeREGISTER_KEYS
ControlOpcodeRegisterShape <- ControlOpcodeREGISTER_SHAPE
ControlOpcodeRegisterStrings <- ControlOpcodeREGISTER_STRINGS
ControlOpcodePromoteStringFieldToEnum <- ControlOpcodePROMOTE_STRING_FIELD_TO_ENUM
ControlOpcodeResetTables <- ControlOpcodeRESET_TABLES
ControlOpcodeResetState <- ControlOpcodeRESET_STATE
PatchOpcodeKeep <- PatchOpcodeKEEP
PatchOpcodeReplaceScalar <- PatchOpcodeREPLACE_SCALAR
PatchOpcodeReplaceVector <- PatchOpcodeREPLACE_VECTOR
PatchOpcodeAppendVector <- PatchOpcodeAPPEND_VECTOR
PatchOpcodeTruncateVector <- PatchOpcodeTRUNCATE_VECTOR
PatchOpcodeDeleteField <- PatchOpcodeDELETE_FIELD
PatchOpcodeInsertField <- PatchOpcodeINSERT_FIELD
PatchOpcodeStringRef <- PatchOpcodeSTRING_REF
PatchOpcodePrefixDelta <- PatchOpcodePREFIX_DELTA
ControlStreamCodecPlain <- ControlStreamCodecPLAIN
ControlStreamCodecRle <- ControlStreamCodecRLE
ControlStreamCodecBitpack <- ControlStreamCodecBITPACK
ControlStreamCodecHuffman <- ControlStreamCodecHUFFMAN
ControlStreamCodecFse <- ControlStreamCodecFSE

new_null <- function() list(kind = ValueKindNULL)
new_bool <- function(b) list(kind = ValueKindBOOL, bool = isTRUE(b))
new_i64 <- function(n) list(kind = ValueKindI64, i64 = as.numeric(n))
new_u64 <- function(n) list(kind = ValueKindU64, u64 = as.numeric(n))
new_f64 <- function(n) list(kind = ValueKindF64, f64 = as.double(n))
new_string <- function(s) list(kind = ValueKindSTRING, str = as.character(s))
new_binary <- function(b) list(kind = ValueKindBINARY, bin = as_raw_input(b))
new_array <- function(items) list(kind = ValueKindARRAY, arr = lapply(items, value_clone))
entry <- function(key, value) list(key = key, value = value_clone(value))
new_map <- function(...) {
  entries <- list(...)
  list(kind = ValueKindMAP, map = lapply(entries, function(e) list(key = e$key, value = value_clone(e$value))))
}

value_is_scalar <- function(v) v$kind != ValueKindARRAY && v$kind != ValueKindMAP

value_clone <- function(v) {
  switch(as.integer(v$kind) + 1L,
    list(kind = ValueKindNULL),
    list(kind = ValueKindBOOL, bool = v$bool %||% FALSE),
    list(kind = ValueKindI64, i64 = v$i64 %||% 0),
    list(kind = ValueKindU64, u64 = v$u64 %||% 0),
    list(kind = ValueKindF64, f64 = v$f64 %||% 0),
    list(kind = ValueKindSTRING, str = v$str %||% ''),
    list(kind = ValueKindBINARY, bin = as.raw(v$bin %||% raw())),
    list(kind = ValueKindARRAY, arr = lapply(v$arr %||% list(), value_clone)),
    list(kind = ValueKindMAP, map = lapply(v$map %||% list(), function(e) list(key = e$key, value = value_clone(e$value))))
  )
}

equal <- function(a, b) {
  if (a$kind != b$kind) return(FALSE)
  switch(as.integer(a$kind) + 1L,
    TRUE,
    identical(a$bool, b$bool),
    a$i64 == b$i64,
    a$u64 == b$u64,
    a$f64 == b$f64,
    identical(a$str, b$str),
    identical(as.raw(a$bin), as.raw(b$bin)),
    {
      if (length(a$arr) != length(b$arr)) return(FALSE)
      all(mapply(equal, a$arr, b$arr, SIMPLIFY = TRUE))
    },
    {
      if (length(a$map) != length(b$map)) return(FALSE)
      all(mapply(function(e1, e2) identical(e1$key, e2$key) && equal(e1$value, e2$value), a$map, b$map, SIMPLIFY = TRUE))
    }
  )
}

key_ref_literal <- function(s) list(literal = s, id = 0L, is_id = FALSE)
key_ref_id <- function(ref_id) list(literal = '', id = as.integer(ref_id), is_id = TRUE)
base_ref_previous <- function() list(previous = TRUE, base_id = 0L)
base_ref_id <- function(ref_id) list(previous = FALSE, base_id = as.numeric(ref_id))

message_kind_from_byte <- function(b) {
  if (b >= 0 && b <= 0x0D) return(list(MessageKindScalar + b - MessageKindScalar, TRUE))
  list(MessageKindScalar, FALSE)
}
string_mode_from_byte <- function(b) if (b >= 0 && b <= 4) list(b, TRUE) else list(0L, FALSE)
element_type_from_byte <- function(b) if (b >= 0 && b <= 6) list(b, TRUE) else list(0L, FALSE)
vector_codec_from_byte <- function(b) if (b <= 12) list(b, TRUE) else list(0L, FALSE)
null_strategy_from_byte <- function(b) if (b >= 0 && b <= 3) list(b, TRUE) else list(0L, FALSE)
control_opcode_from_byte <- function(b) if (b >= 0 && b <= 5) list(b, TRUE) else list(0L, FALSE)
patch_opcode_from_byte <- function(b) if (b <= 8) list(b, TRUE) else list(0L, FALSE)
control_stream_codec_from_byte <- function(b) if (b <= 4) list(b, TRUE) else list(0L, FALSE)

new_message <- function(kind, ...) {
  msg <- list(kind = kind)
  extras <- list(...)
  for (nm in names(extras)) msg[[nm]] <- extras[[nm]]
  msg
}

message_clone <- function(msg) serialize(msg, NULL) %>% unserialize()
