package io.twilic.internal.core;

import java.util.ArrayList;
import java.util.List;

public final class Schema {
  public long schemaId;
  public String name;
  public List<SchemaField> fields = new ArrayList<>();
}
