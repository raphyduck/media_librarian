class ClientInput < EM::Connection
  include EM::Protocols::LineText2

  attr_reader :queue

  def initialize
  end

  def receive_line(data)
    $daemon_client.send_data("user_input #{data}") if $daemon_client
  end
end