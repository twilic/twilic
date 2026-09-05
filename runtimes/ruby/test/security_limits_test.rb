require "test_helper"
class SecurityLimitsTest < Minitest::Test
  def test_depth_and_budget
    assert_raises(Twilic::Core::Errors::TwilicError) { Twilic.decode(([0xa1] * 70 + [0xc0]).pack("C*")) }
    reader = Twilic::Core::Wire::Reader.new("\0")
    reader.claim_output(100)
    assert_raises(Twilic::Core::Errors::TwilicError) { reader.claim_output(100) }
    assert_raises(Twilic::Core::Errors::TwilicError) { reader.read_exact(-1) }
  end
end
