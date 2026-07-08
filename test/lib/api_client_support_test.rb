# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../lib/api_client_support'

class ApiClientSupportTest < Minitest::Test
  class Dummy
    include ApiClientSupport
    public :with_retries, :backoff_delay
    def initialize; @speaker = nil; end
  end

  def setup
    @c = Dummy.new
  end

  def test_retries_then_succeeds_on_transient_error
    calls = 0
    result = @c.stub(:sleep, nil) do
      @c.with_retries(base_delay: 0) do
        calls += 1
        raise Net::ReadTimeout if calls < 3
        :ok
      end
    end
    assert_equal :ok, result
    assert_equal 3, calls, 'retried until success'
  end

  def test_gives_up_after_max_attempts_and_reraises
    calls = 0
    err = assert_raises(Net::ReadTimeout) do
      @c.stub(:sleep, nil) do
        @c.with_retries(max_attempts: 3, base_delay: 0) { calls += 1; raise Net::ReadTimeout }
      end
    end
    assert_instance_of Net::ReadTimeout, err
    assert_equal 3, calls, 'stopped at max_attempts'
  end

  def test_rate_limited_honours_retry_after
    slept = []
    calls = 0
    @c.stub(:sleep, ->(s) { slept << s }) do
      @c.with_retries(base_delay: 0) do
        calls += 1
        raise ApiClientSupport::RateLimitedError.new(retry_after: 7) if calls < 2
        :done
      end
    end
    assert_equal [7], slept, 'used Retry-After value'
  end

  def test_backoff_grows_and_is_capped
    d1 = @c.backoff_delay(1, 1.0, 30.0)
    d5 = @c.backoff_delay(5, 1.0, 30.0)
    assert d1 >= 1.0 && d1 <= 1.25
    assert d5 <= 30.0 * 1.25, 'capped at max_delay + jitter'
  end
end
