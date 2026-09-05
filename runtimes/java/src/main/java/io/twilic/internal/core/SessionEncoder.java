package io.twilic.internal.core;

import java.util.ArrayList;
import java.util.List;

public final class SessionEncoder {
  private final InternalSessionEncoder impl;

  public SessionEncoder() {
    this(new SessionOptions());
  }

  public SessionEncoder(SessionOptions options) {
    this.impl = new InternalSessionEncoder(options);
  }

  public byte[] encode(Value value) {
    return impl.encode(value);
  }

  public byte[] encodeWithSchema(Schema schema, Value value) {
    return impl.encodeWithSchema(schema, value);
  }

  public byte[] encodeBatch(List<Value> values) {
    return impl.encodeBatch(values == null ? new ArrayList<>() : values);
  }

  public byte[] encodePatch(Value value) {
    return impl.encodePatch(value);
  }

  public byte[] encodeMicroBatch(List<Value> values) {
    return impl.encodeMicroBatch(values == null ? new ArrayList<>() : values);
  }

  public void reset() {
    impl.reset();
  }

  public Message decodeMessage(byte[] data) {
    return impl.decodeMessage(data);
  }
}

final class InternalSessionEncoder {
  final TwilicCodec codec;

  InternalSessionEncoder(SessionOptions options) {
    this.codec = new TwilicCodec(options);
  }

  byte[] encode(Value value) {
    Message msg = codec.messageForValue(value);
    if (codec.state.options.enableStatePatch
        && codec.state.previousMessage != null
        && ProtocolHelpers.supportsStatePatch(codec.state.previousMessage, msg)) {
      ProtocolHelpers.DiffMessageResult diff =
          ProtocolHelpers.diffMessage(codec.state.previousMessage, msg);
      StatePatchMessage patch = new StatePatchMessage();
      patch.baseRef = BaseRef.previous();
      patch.operations = diff.operations();
      Message patchMsg = new Message();
      patchMsg.kind = MessageKind.STATE_PATCH;
      patchMsg.statePatch = patch;
      if (ProtocolHelpers.encodedSize(patchMsg) < ProtocolHelpers.encodedSize(msg)) {
        try {
          return codec.encodeMessage(patchMsg);
        } catch (Throwable ignore) {
          // fall back to full message
        }
      }
    }
    return codec.encodeMessage(msg);
  }

  byte[] encodeWithSchema(Schema schema, Value value) {
    codec.state.schemas.put(schema.schemaId, schema);
    codec.state.lastSchemaId = schema.schemaId;
    for (SchemaField field : schema.fields) {
      if (!field.enumValues.isEmpty()) {
        codec.state.fieldEnums.put(field.name, new ArrayList<>(field.enumValues));
      }
    }
    if (value.kind != ValueKind.MAP) {
      throw Errors.invalidData("encode_with_schema expects map value");
    }
    List<Boolean> presence = new ArrayList<>();
    List<Value> fields = new ArrayList<>();
    boolean hasPresence = false;
    for (SchemaField field : schema.fields) {
      Value v = ProtocolHelpers.lookupMapField(value, field.name);
      if (v != null) {
        presence.add(true);
        fields.add(ProtocolHelpers.cloneValue(v));
      } else {
        presence.add(false);
        hasPresence = true;
      }
    }
    SchemaObjectMessage schemaObject = new SchemaObjectMessage();
    schemaObject.schemaId = schema.schemaId;
    schemaObject.presence = presence;
    schemaObject.hasPresence = hasPresence;
    schemaObject.fields = fields;
    Message msg = new Message();
    msg.kind = MessageKind.SCHEMA_OBJECT;
    msg.schemaObject = schemaObject;
    return codec.encodeMessage(msg);
  }

  byte[] encodeBatch(List<Value> values) {
    Message msg;
    if (values.isEmpty()) {
      RowBatchMessage rowBatch = new RowBatchMessage();
      msg = new Message();
      msg.kind = MessageKind.ROW_BATCH;
      msg.rowBatch = rowBatch;
      return codec.encodeMessage(msg);
    }
    if (values.size() >= 16) {
      List<Column> cols = ProtocolHelpers.columnsFromMapValues(values);
      if (cols == null) {
        cols = ProtocolHelpers.rowsToColumns(ProtocolHelpers.rowsFromValues(values));
      }
      if (codec.state.options.enableTrainedDictionary) {
        Dictionary.applyDictionaryReferences(codec.state, cols);
      }
      ColumnBatchMessage columnBatch = new ColumnBatchMessage();
      columnBatch.count = values.size();
      columnBatch.columns = cols;
      msg = new Message();
      msg.kind = MessageKind.COLUMN_BATCH;
      msg.columnBatch = columnBatch;
    } else {
      RowBatchMessage rowBatch = new RowBatchMessage();
      rowBatch.rows = ProtocolHelpers.rowsFromValues(values);
      msg = new Message();
      msg.kind = MessageKind.ROW_BATCH;
      msg.rowBatch = rowBatch;
    }
    byte[] bytes = codec.encodeMessage(msg);
    codec.state.previousMessage = msg;
    codec.state.previousMessageSize = bytes.length;
    recordFullMessageAsBase();
    return bytes;
  }

  byte[] encodePatch(Value value) {
    Message msg = codec.messageForValue(value);
    if (codec.state.previousMessage == null
        || !ProtocolHelpers.supportsStatePatch(codec.state.previousMessage, msg)) {
      return codec.encodeMessage(msg);
    }
    ProtocolHelpers.DiffMessageResult diff =
        ProtocolHelpers.diffMessage(codec.state.previousMessage, msg);
    StatePatchMessage patch = new StatePatchMessage();
    patch.baseRef = BaseRef.previous();
    patch.operations = diff.operations();
    Message patchMsg = new Message();
    patchMsg.kind = MessageKind.STATE_PATCH;
    patchMsg.statePatch = patch;
    if (ProtocolHelpers.encodedSize(patchMsg) >= ProtocolHelpers.encodedSize(msg)) {
      return codec.encodeMessage(msg);
    }
    return codec.encodeMessage(patchMsg);
  }

  byte[] encodeMicroBatch(List<Value> values) {
    if (values.isEmpty()) {
      return encodeBatch(values);
    }
    if (!codec.state.options.enableTemplateBatch
        || !ProtocolHelpers.hasUniformMicroBatchShape(values)) {
      return encodeBatch(values);
    }
    List<Column> columns = ProtocolHelpers.columnsFromMapValues(values);
    if (columns == null) {
      columns = ProtocolHelpers.rowsToColumns(ProtocolHelpers.rowsFromValues(values));
    }
    if (codec.state.options.enableTrainedDictionary) {
      Dictionary.applyDictionaryReferences(codec.state, columns);
    }
    Long templateId = ProtocolHelpers.findTemplateId(codec.state.templates, columns);
    if (templateId == null) {
      templateId = ProtocolHelpers.allocateTemplateId(codec.state);
      codec.state.templates.put(
          templateId, ProtocolHelpers.templateDescriptorFromColumns(templateId, columns));
      codec.state.templateColumns.put(templateId, columns);
      TemplateBatchMessage batch = new TemplateBatchMessage();
      batch.templateId = templateId;
      batch.count = values.size();
      for (int i = 0; i < columns.size(); i++) {
        batch.changedColumnMask.add(true);
      }
      batch.columns = columns;
      Message msg = new Message();
      msg.kind = MessageKind.TEMPLATE_BATCH;
      msg.templateBatch = batch;
      return codec.encodeMessage(msg);
    }
    ProtocolHelpers.DiffTemplateResult diff =
        ProtocolHelpers.diffTemplateColumns(codec.state.templateColumns.get(templateId), columns);
    codec.state.templateColumns.put(templateId, columns);
    TemplateBatchMessage batch = new TemplateBatchMessage();
    batch.templateId = templateId;
    batch.count = values.size();
    batch.changedColumnMask = diff.mask();
    batch.columns = diff.changed();
    Message msg = new Message();
    msg.kind = MessageKind.TEMPLATE_BATCH;
    msg.templateBatch = batch;
    return codec.encodeMessage(msg);
  }

  void reset() {
    ProtocolHelpers.resetState(codec.state);
  }

  Message decodeMessage(byte[] data) {
    return codec.decodeMessage(data);
  }

  private void recordFullMessageAsBase() {
    if (codec.state.options.maxBaseSnapshots == 0) {
      return;
    }
    if (codec.state.previousMessage == null) {
      return;
    }
    long baseId = ProtocolHelpers.allocateBaseId(codec.state);
    ProtocolHelpers.registerBaseSnapshot(codec.state, baseId, codec.state.previousMessage);
  }
}
