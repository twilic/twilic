# frozen_string_literal: true

require "twilic/core/model"
require "twilic/core/protocol"

module Twilic
  module Core
    module InteropFixtures
      InteropFrame = Data.define(:stream, :label, :hex, :bytes)

      module_function

      def interop_id_name_map(id, name)
        Model.map_value("id" => Model.u64_value(id), "name" => Model.string_value(name))
      end

      def interop_id_name_role_map(id, name, role)
        Model.map_value(
          "id" => Model.u64_value(id),
          "name" => Model.string_value(name),
          "role" => Model.string_value(role)
        )
      end

      def interop_make_i64_array(length, start)
        Array.new(length) { |i| Model.i64_value(start + i) }
      end

      def interop_make_user_rows(names)
        names.each_with_index.map do |name, i|
          Model.map_value("id" => Model.u64_value(i + 1), "name" => Model.string_value(name))
        end
      end

      def interop_bitpack_control_payload
        Array.new(512) { |i| i.even? ? 0 : 1 }.pack("C*")
      end

      def interop_huffman_control_payload
        Array.new(512, 7).pack("C*")
      end

      def interop_fse_control_payload
        Array.new(512) { |i| i % 4 }.pack("C*")
      end

      def reset_encode_shape_observation(codec, keys)
        key = codec.shape_key(keys)
        codec.state.encode_shape_observations.delete(key)
      end

      def emit_interop_fixtures(out)
        codec = Protocol::TwilicCodec.new

        alpha = Model.string_value("alpha")
        emit_interop_value(out, "codec", "scalar_string", codec, alpha)

        map_two = interop_id_name_map(1, "alice")
        emit_interop_value(out, "codec", "map_two_fields_first", codec, map_two)
        reset_encode_shape_observation(codec, %w[id name])
        emit_interop_value(out, "codec", "map_two_fields_second", codec, map_two)

        map_three = interop_id_name_role_map(1, "alice", "admin")
        emit_interop_value(out, "codec", "map_three_fields_first", codec, map_three)
        reset_encode_shape_observation(codec, %w[id name role])
        emit_interop_value(out, "codec", "map_three_fields_second", codec, map_three)

        8.times do |i|
          dynamic = interop_id_name_map(10 + i, "user-#{i}")
          emit_interop_value(out, "codec", "bulk_map_#{i}", codec, dynamic)
        end

        scalar = Model.i64_value(42)
        base_snapshot = Model.message(
          kind: Model::MessageKind::BASE_SNAPSHOT,
          base_snapshot: Model::BaseSnapshotMessage.new(
            base_id: 77,
            schema_or_shape_ref: 0,
            payload: Model.message(kind: Model::MessageKind::SCALAR, scalar: scalar)
          )
        )
        emit_interop_message(out, "codec", "base_snapshot", codec, base_snapshot)

        enc = Protocol::SessionEncoder.new(Session::SessionOptions.default)
        base_array = Model.array_value(interop_make_i64_array(100, 0))
        base_bytes = enc.encode(base_array)
        emit_interop_frame(out, "session", "session_base_array", base_bytes)

        one_change_arr = interop_make_i64_array(100, 0)
        one_change_arr[0] = Model.i64_value(10_000)
        one_change = Model.array_value(one_change_arr)
        one_patch = enc.encode_patch(one_change)
        emit_interop_frame(out, "session", "session_patch_one_change", one_patch)

        4.times do |step|
          iter_arr = interop_make_i64_array(100, 0)
          iter_arr[step] = Model.i64_value(20_000 + step)
          iterative = Model.array_value(iter_arr)
          bytes = enc.encode_patch(iterative)
          emit_interop_frame(out, "session", "session_patch_iter_#{step}", bytes)
        end

        many_arr = interop_make_i64_array(100, 0)
        12.times { |idx| many_arr[idx] = Model.i64_value(10_000 + idx) }
        many_change = Model.array_value(many_arr)
        many_patch = enc.encode_patch(many_change)
        emit_interop_frame(out, "session", "session_patch_many_changes", many_patch)

        rows1 = interop_make_user_rows(%w[a b c d])
        micro_first = enc.encode_micro_batch(rows1)
        emit_interop_frame(out, "session", "session_micro_batch_first", micro_first)

        rows2 = interop_make_user_rows(%w[aa bb cc dd])
        micro_second = enc.encode_micro_batch(rows2)
        emit_interop_frame(out, "session", "session_micro_batch_second", micro_second)
      end

      def emit_interop_value(out, stream, label, codec, value)
        bytes = codec.encode_value(value)
        emit_interop_frame(out, stream, label, bytes)
      end

      def emit_interop_message(out, stream, label, codec, message)
        bytes = codec.encode_message(message)
        emit_interop_frame(out, stream, label, bytes)
      end

      def emit_interop_frame(out, stream, label, bytes)
        hex = "0123456789abcdef"
        encoded = bytes.each_byte.map { |b| hex[b >> 4] + hex[b & 0x0f] }.join
        frame = "#{stream}|#{label}|#{encoded}\n"
        if out.respond_to?(:<<)
          out << frame
        else
          out.write(frame)
        end
      end

      def parse_interop_frames(input)
        frames = []
        input.each_line.with_index do |raw_line, line_no|
          line = raw_line.strip
          next if line.empty?

          begin
            stream, label, hex = parse_interop_frame_line(line)
            bytes = decode_interop_hex(hex)
            frames << InteropFrame.new(stream: stream, label: label, hex: hex, bytes: bytes)
          rescue StandardError => e
            raise "line #{line_no + 1}: #{e.message}"
          end
        end
        raise "no fixture frames found" if frames.empty?

        frames
      end

      def parse_interop_frame_line(line)
        first = line.index("|")
        raise "invalid frame" if first.nil? || first <= 0

        rest = line[(first + 1)..]
        second = rest.index("|")
        raise "invalid frame" if second.nil? || second <= 0

        [line[0...first], rest[0...second], rest[(second + 1)..]]
      end

      def decode_interop_hex(hex)
        raise "invalid hex length" unless hex.length.even?

        hex.chars.each_slice(2).map do |hi, lo|
          (interop_hex_nibble(hi) << 4) | interop_hex_nibble(lo)
        end.pack("C*")
      end

      def interop_hex_nibble(ch)
        case ch
        when "0".."9" then ch.ord - "0".ord
        when "a".."f" then ch.ord - "a".ord + 10
        when "A".."F" then ch.ord - "A".ord + 10
        else
          raise "invalid hex"
        end
      end

      def interop_expect_codec_value(label)
        case label
        when "scalar_string"
          [Model.string_value("alpha"), true]
        else
          if label.start_with?("map_two_fields_")
            [interop_id_name_map(1, "alice"), true]
          elsif label.start_with?("map_three_fields_")
            [interop_id_name_role_map(1, "alice", "admin"), true]
          elsif label.start_with?("bulk_map_")
            idx = label.delete_prefix("bulk_map_").to_i
            [interop_id_name_map(10 + idx, "user-#{idx}"), true]
          else
            [nil, false]
          end
        end
      end

      def interop_expect_codec_value?(label)
        interop_expect_codec_value(label)[1]
      end

      def interop_expect_control_stream_codec(label)
        case label
        when "control_stream_bitpack" then [Model::ControlStreamCodec::BITPACK, true]
        when "control_stream_huffman" then [Model::ControlStreamCodec::HUFFMAN, true]
        when "control_stream_fse" then [Model::ControlStreamCodec::FSE, true]
        else
          [nil, false]
        end
      end

      def interop_expect_control_payload(label)
        case label
        when "control_stream_bitpack" then [interop_bitpack_control_payload, true]
        when "control_stream_huffman" then [interop_huffman_control_payload, true]
        when "control_stream_fse" then [interop_fse_control_payload, true]
        else
          [nil, false]
        end
      end

      def interop_expect_control_payload?(label)
        interop_expect_control_payload(label)[1]
      end

      def assert_interop_codec_decode(codec, label, frame)
        case label
        when "base_snapshot"
          msg = codec.decode_message(frame)
          raise "expected base snapshot message" unless msg.kind == Model::MessageKind::BASE_SNAPSHOT && msg.base_snapshot
          raise "base_id: got #{msg.base_snapshot.base_id} want 77" unless msg.base_snapshot.base_id == 77

          payload = msg.base_snapshot.payload
          unless payload.kind == Model::MessageKind::SCALAR &&
                 payload.scalar&.kind == Model::ValueKind::I64 &&
                 payload.scalar.i64 == 42
            raise "base snapshot payload mismatch"
          end
          return
        end

        _payload, ok = interop_expect_control_payload(label)
        if ok
          msg = codec.decode_message(frame)
          raise "expected control stream message" unless msg.kind == Model::MessageKind::CONTROL_STREAM && msg.control_stream
          raise "control stream payload empty for #{label}" if msg.control_stream.payload.empty?

          want_codec, codec_ok = interop_expect_control_stream_codec(label)
          if codec_ok && msg.control_stream.codec != want_codec
            raise "control stream codec mismatch for #{label}"
          end
          return
        end

        expected, ok = interop_expect_codec_value(label)
        raise "no codec expectation for label #{label.inspect}" unless ok

        got = codec.decode_value(frame)
        raise "decoded value mismatch for #{label}" unless Model.equal(got, expected)
      end

      def assert_interop_session_decode(codec, label, frame)
        case label
        when "session_base_array"
          got = codec.decode_value(frame)
          want = Model.array_value(interop_make_i64_array(100, 0))
          raise "session_base_array value mismatch" unless Model.equal(got, want)
        when "session_patch_one_change"
          msg = codec.decode_message(frame)
          want_arr = interop_make_i64_array(100, 0)
          want_arr[0] = Model.i64_value(10_000)
          want = Model.array_value(want_arr)
          case msg.kind
          when Model::MessageKind::STATE_PATCH
            return
          when Model::MessageKind::TYPED_VECTOR
            raise "session_patch_one_change: missing typed vector" unless msg.typed_vector

            got = Protocol.send(:typed_vector_to_value, msg.typed_vector)
            raise "session_patch_one_change typed vector mismatch" unless Model.equal(got, want)
          when Model::MessageKind::ARRAY
            got = Model.array_value(msg.array)
            raise "session_patch_one_change array mismatch" unless Model.equal(got, want)
          else
            raise "session_patch_one_change: unexpected kind #{msg.kind}"
          end
        when "session_patch_many_changes", "session_micro_batch_first", "session_micro_batch_second"
          msg = codec.decode_message(frame)
          case label
          when "session_patch_many_changes"
            unless [Model::MessageKind::STATE_PATCH, Model::MessageKind::TYPED_VECTOR,
                    Model::MessageKind::ARRAY].include?(msg.kind)
              raise "expected patch or array message, got #{msg.kind}"
            end
          when "session_micro_batch_first", "session_micro_batch_second"
            unless msg.kind == Model::MessageKind::TEMPLATE_BATCH && msg.template_batch
              raise "expected template batch message, got #{msg.kind}"
            end
            raise "expected 4 rows, got #{msg.template_batch.count}" unless msg.template_batch.count == 4
          end
        else
          if label.start_with?("session_patch_iter_")
            msg = codec.decode_message(frame)
            unless [Model::MessageKind::STATE_PATCH, Model::MessageKind::TYPED_VECTOR,
                    Model::MessageKind::ARRAY].include?(msg.kind)
              raise "#{label}: expected patch or array message, got #{msg.kind}"
            end
            return
          end
          raise "no session expectation for label #{label.inspect}"
        end
      end

      def replay_codec_state(frames, stop_label)
        iso = Protocol::TwilicCodec.new
        frames.each do |prior|
          next unless prior.stream == "codec"
          break if prior.label == stop_label

          _payload, ok = interop_expect_control_payload(prior.label)
          if ok || prior.label == "base_snapshot"
            iso.decode_message(prior.bytes)
            next
          end

          _expected, value_ok = interop_expect_codec_value(prior.label)
          iso.decode_value(prior.bytes) if value_ok
        end
        iso
      end
    end
  end
end
