package io.twilic

import io.twilic.internal.core.*
import java.util as ju

object Twilic {
  def encode(value: Value): Array[Byte] = Api.Encode(value)

  def decode(bytes: Array[Byte]): Value = Api.Decode(bytes)

  def encodeWithSchema(schema: Schema, value: Value): Array[Byte] =
    Api.EncodeWithSchema(schema, value)

  def encodeBatch(values: ju.List[Value]): Array[Byte] = Api.EncodeBatch(values)

  def newNull(): Value = Value.ofNull()

  def newBool(b: Boolean): Value = Value.ofBool(b)

  def newI64(n: Long): Value = Value.ofI64(n)

  def newU64(n: Long): Value = Value.ofU64(n)

  def newF64(n: Double): Value = Value.ofF64(n)

  def newString(s: String): Value = Value.ofString(s)

  def newBinary(b: Array[Byte]): Value = Value.ofBinary(b)

  def newArray(items: ju.List[Value]): Value = Value.ofArray(items)

  def entry(key: String, value: Value): MapEntry = new MapEntry(key, value)

  def newMap(entries: MapEntry*): Value =
    Value.ofMap(new ju.ArrayList(ju.Arrays.asList(entries*)))

  def equal(a: Value, b: Value): Boolean = {
    if (a.kind != b.kind) return false
    a.kind match {
      case ValueKind.NULL   => true
      case ValueKind.BOOL   => a.bool == b.bool
      case ValueKind.I64    => a.i64 == b.i64
      case ValueKind.U64    => a.u64 == b.u64
      case ValueKind.F64    => java.lang.Double.compare(a.f64, b.f64) == 0
      case ValueKind.STRING => a.str == b.str
      case ValueKind.BINARY => ju.Arrays.equals(a.bin, b.bin)
      case ValueKind.ARRAY =>
        if (a.arr.size != b.arr.size) false
        else {
          var same = true
          var i    = 0
          while (i < a.arr.size && same) {
            if (!equal(a.arr.get(i), b.arr.get(i))) same = false
            i += 1
          }
          same
        }
      case ValueKind.MAP =>
        if (a.map.size != b.map.size) false
        else {
          var same = true
          var i    = 0
          while (i < a.map.size && same) {
            val ea = a.map.get(i)
            val eb = b.map.get(i)
            if (ea.key != eb.key || !equal(ea.value, eb.value)) same = false
            i += 1
          }
          same
        }
    }
  }

  def keyRefLiteral(s: String): KeyRef = KeyRef.literal(s)

  def keyRefID(id: Long): KeyRef = KeyRef.id(id)

  def baseRefPrevious(): BaseRef = BaseRef.previous()

  def baseRefID(id: Long): BaseRef = BaseRef.id(id)

  def newSessionEncoder(): SessionEncoder = new SessionEncoder()
}
