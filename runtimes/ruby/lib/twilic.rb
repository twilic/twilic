# frozen_string_literal: true

require "twilic/version"
require "twilic/core/errors"
require "twilic/core/model"
require "twilic/core/wire"
require "twilic/core/codec"
require "twilic/core/session"
require "twilic/core/dictionary"
require "twilic/core/v2"
require "twilic/core/protocol"
require "twilic/core/api"

module Twilic
  # Types
  MessageKind = Core::Model::MessageKind
  ValueKind = Core::Model::ValueKind
  Value = Core::Model::Value
  MapEntry = Core::Model::MapEntry
  MessageMapEntry = Core::Model::MessageMapEntry
  KeyRef = Core::Model::KeyRef
  StringMode = Core::Model::StringMode
  StringValue = Core::Model::StringValue
  ElementType = Core::Model::ElementType
  VectorCodec = Core::Model::VectorCodec
  TypedVectorData = Core::Model::TypedVectorData
  TypedVector = Core::Model::TypedVector
  SchemaField = Core::Model::SchemaField
  Schema = Core::Model::Schema
  NullStrategy = Core::Model::NullStrategy
  Column = Core::Model::Column
  ControlOpcode = Core::Model::ControlOpcode
  ControlMessage = Core::Model::ControlMessage
  RegisterShapeControl = Core::Model::RegisterShapeControl
  PromoteEnumControl = Core::Model::PromoteEnumControl
  PatchOpcode = Core::Model::PatchOpcode
  BaseRef = Core::Model::BaseRef
  PatchOperation = Core::Model::PatchOperation
  ControlStreamCodec = Core::Model::ControlStreamCodec
  Message = Core::Model::Message
  ShapedObjectMessage = Core::Model::ShapedObjectMessage
  SchemaObjectMessage = Core::Model::SchemaObjectMessage
  RowBatchMessage = Core::Model::RowBatchMessage
  ColumnBatchMessage = Core::Model::ColumnBatchMessage
  ExtMessage = Core::Model::ExtMessage
  StatePatchMessage = Core::Model::StatePatchMessage
  TemplateBatchMessage = Core::Model::TemplateBatchMessage
  ControlStreamMessage = Core::Model::ControlStreamMessage
  BaseSnapshotMessage = Core::Model::BaseSnapshotMessage
  TemplateDescriptor = Core::Model::TemplateDescriptor
  TwilicError = Core::Errors::TwilicError
  UnknownReferencePolicy = Core::Session::UnknownReferencePolicy
  DictionaryFallback = Core::Session::DictionaryFallback
  DictionaryProfile = Core::Session::DictionaryProfile
  SessionOptions = Core::Session::SessionOptions
  SessionState = Core::Session::MutableSessionState
  TwilicCodec = Core::Protocol::TwilicCodec
  SessionEncoder = Core::Protocol::SessionEncoder

  # Error constants
  ERR_UNEXPECTED_EOF = Core::Errors::UNEXPECTED_EOF
  ERR_INVALID_KIND = Core::Errors::INVALID_KIND
  ERR_INVALID_TAG = Core::Errors::INVALID_TAG
  ERR_INVALID_DATA = Core::Errors::INVALID_DATA
  ERR_UTF8 = Core::Errors::UTF8
  ERR_UNKNOWN_REFERENCE = Core::Errors::UNKNOWN_REFERENCE
  ERR_STATELESS_RETRY_REQUIRED = Core::Errors::STATELESS_RETRY_REQUIRED

  class << self
    def encode(value)
      Core::API.encode(value)
    end

    def decode(bytes)
      Core::API.decode(bytes)
    end

    def encode_with_schema(schema, value)
      Core::API.encode_with_schema(schema, value)
    end

    def encode_batch(values)
      Core::API.encode_batch(values)
    end

    def null
      Core::Model.null_value
    end

    def bool(b)
      Core::Model.bool_value(b)
    end

    def i64(n)
      Core::Model.i64_value(n)
    end

    def u64(n)
      Core::Model.u64_value(n)
    end

    def f64(n)
      Core::Model.f64_value(n)
    end

    def string(s)
      Core::Model.string_value(s)
    end

    def binary(b)
      Core::Model.binary_value(b)
    end

    def array(items)
      Core::Model.array_value(items)
    end

    def map(**kwargs)
      Core::Model.map_value(kwargs)
    end

    def equal(a, b)
      Core::Model.equal(a, b)
    end

    def default_session_options
      Core::Session::SessionOptions.default
    end

    def new_twilic_codec
      TwilicCodec.new
    end

    def twilic_codec_with_options(options)
      TwilicCodec.new(options)
    end

    def new_session_encoder(options = default_session_options)
      SessionEncoder.new(options)
    end

    def reset_encode_shape_observation(codec, keys)
      key = codec.shape_key(keys)
      codec.state.encode_shape_observations.delete(key)
    end
  end
end
