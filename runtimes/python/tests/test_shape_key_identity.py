"""Shape identity must preserve key boundaries and arbitrary string contents."""

from twilic import MapEntry, equal, new_array, new_i64, new_map, new_twilic_codec, new_u64
from twilic.session import ShapeTable, shape_key
from twilic.v2 import decode_v2, encode_v2


def test_shape_keys_preserve_boundaries_and_empty_keys():
    shapes = [["a", "b"], ["a\0b"], [], [""], ["a\0", "b"], ["a", "\0b"]]
    table = ShapeTable()
    ids = [table.register(keys) for keys in shapes]
    assert len(set(ids)) == len(shapes)
    assert len({shape_key(keys) for keys in shapes}) == len(shapes)
    for keys, shape_id in zip(shapes, ids, strict=True):
        assert table.register(keys) == shape_id
        assert table.get_id(keys) == (shape_id, True)
        assert table.observe(keys) == 1
        assert table.observe(keys) == 2
    assert not table.register_with_id(ids[0], shapes[1])


def test_session_does_not_reuse_shape_containing_nul():
    encoder, decoder = new_twilic_codec(), new_twilic_codec()
    for codec in (encoder, decoder):
        codec.state.shape_table.register(["a\0b"])
    value = new_map(MapEntry("a", new_i64(2)), MapEntry("b", new_i64(3)))
    assert equal(decoder.decode_value(encoder.encode_value(value)), value)


def test_v2_nested_maps_do_not_share_colliding_shapes():
    value = new_map(
        MapEntry("left", new_array([new_map(MapEntry("a\0b", new_u64(1)))] * 2)),
        MapEntry(
            "right",
            new_array([new_map(MapEntry("a", new_u64(2)), MapEntry("b", new_u64(3)))] * 2),
        ),
    )
    assert equal(decode_v2(encode_v2(value)), value)
