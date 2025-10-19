class Client < EventMachine::Connection
  include MediaLibrarian::AppContainerSupport

  def initialize(args)
    @args = args
    self.class.app.daemon_client = self
  end

  def post_init
    send_data "hello from #{Socket.gethostname}"
  end

  def receive_data(data)
    case data
      when /identify yourself first/
        send_data "hello from #{Socket.gethostname}"
      when /listening/
        send_data @args
      else
        data.scan(/[^\n]*/).each {|d| puts d if d != '' && d != 'bye' }
    end
    EventMachine::stop_event_loop if data.match(/^bye/)
  end
end