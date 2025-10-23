# frozen_string_literal: true

require 'test_helper'
require 'hanami/mailer'
require_relative '../../app/report'
require_relative '../../lib/string_utils'

class ReportTest < Minitest::Test
  NEW_LINE_VALUE = "\n".freeze

  def setup
    @environment = build_stubbed_environment
    MediaLibrarian.application = @environment.application
    @environment.application.email_templates = File.expand_path('../../app/mailer_templates', __dir__)
    @environment.application.email = {
      'notification_from' => 'from@example.com',
      'notification_to' => 'to@example.com'
    }

    Object.const_set(:NEW_LINE, NEW_LINE_VALUE) unless Object.const_defined?(:NEW_LINE)

    Mail::TestMailer.deliveries.clear if defined?(Mail::TestMailer)
    Hanami::Mailer.configuration = Hanami::Mailer::Configuration.new
    Hanami::Mailer.configuration.add_mailer(Report)
    Report.configuration = Hanami::Mailer.configuration.duplicate
    Hanami::Mailer.configuration.copy!(Report)
    email_templates = @environment.application.email_templates
    Hanami::Mailer.configure do
      root email_templates
      delivery_method :test
    end.load!
  end

  def teardown
    Mail::TestMailer.deliveries.clear if defined?(Mail::TestMailer)
    Hanami::Mailer.configuration = Hanami::Mailer::Configuration.new
    MediaLibrarian.application = nil
    @environment.cleanup if @environment
  end

  def test_push_email_sanitizes_invalid_subjects_before_delivery
    invalid_subject = "Report".dup.force_encoding('ASCII-8BIT') << "\xC3"
    body = "Job finished with résumé entries"

    assert_sends_email(subject: StringUtils.fix_encoding(invalid_subject), body: body) do
      Report.push_email(invalid_subject, body)
    end
  end

  private

  def assert_sends_email(subject:, body:)
    yield

    deliveries = Mail::TestMailer.deliveries
    assert_equal 1, deliveries.size, 'Expected an email to be delivered'

    mail = deliveries.first
    expected_subject = Report.formatted_subject(subject)
    assert_equal expected_subject, mail.subject
    assert_includes mail.text_part.body.decoded, body
  end
end
