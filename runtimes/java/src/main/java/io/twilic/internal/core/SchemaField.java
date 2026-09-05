package io.twilic.internal.core;

import java.util.ArrayList;
import java.util.List;

public final class SchemaField {
  public long number;
  public String name;
  public String logicalType;
  public boolean required;
  public Value defaultValue;
  public Long min;
  public Long max;
  public List<String> enumValues = new ArrayList<>();
}
