require 'uri'
require 'net/http'
class Tmdb

  def initialize(api_key)
    @api_key = api_key
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    raise e
  end

  def get(method, path, params = {})
    url = URI(URI.escape("https://api.themoviedb.org/3/#{method}/#{path}?" + params.map { |k, v| [k.to_s, "=#{v}&"] }.join +
                  "api_key=#{@api_key}"))
    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    request = Net::HTTP::Get.new(url)
    request.body = "{}"
    response = http.request(request)
    r = JSON.parse(response.read_body)
    r = r['results'] if r['results']
    r
  end

  def method_missing(name, *args)
    $tmdb.get(name, *args)
  rescue => e
    $speaker.tell_error(e, Utils.arguments_dump(binding))
    {}
  end
end