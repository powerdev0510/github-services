$LOAD_PATH.unshift *Dir["#{File.dirname(__FILE__)}/vendor/**/lib"]

# stdlib
require 'net/http'
require 'net/https'
require 'net/smtp'
require 'socket'
require 'timeout'
require 'xmlrpc/client'
require 'openssl'
require 'cgi'
#~ require 'date' # This is needed by the CIA service in ruby 1.8.7 or later

# vendor
require 'mime/types'
require 'xmlsimple'
require 'activesupport'
require 'rack'
require 'sinatra'
require 'tinder'
require 'json'
require 'tinder'
require 'basecamp'
require 'tmail'
require 'xmpp4r'
require 'xmpp4r-simple'
require 'rubyforge'

set :run, true
set :environment, :production
set :port, ARGV.first || 8080

HOSTNAME = `hostname`.chomp

begin
  require 'mongrel'
  set :server, 'mongrel'
rescue LoadError
  begin
    require 'thin'
    set :server, 'thin'
  rescue LoadError
    set :server, 'webrick'
  end
end

module GitHub
  class ServiceTimeout < Timeout::Error
  end

  # Raised when an unexpected error occurs during service hook execution.
  class ServiceError < StandardError
    attr_reader :original_exception
    def initialize(message, original_exception=nil)
      original_exception = message if message.kind_of?(Exception)
      @original_exception = original_exception
      super(message)
    end
  end

  # Raised when a service hook fails due to bad configuration. Services that
  # fail with this exception may be automatically disabled.
  class ServiceConfigurationError < ServiceError
  end

  def service(name)
    post "/#{name}/" do
      begin
        data    = JSON.parse(params[:data])
        payload = parse_payload(params[:payload])
        Timeout.timeout(20, ServiceTimeout) { yield data, payload }
        status 200
        ""
      rescue GitHub::ServiceConfigurationError => boom
        status 400
        boom.message
      rescue GitHub::ServiceTimeout => boom
        status 504
        "Service Timeout"
      rescue Object => boom
        # redact sensitive info in hook_data hash
        hook_data = data || params[:data]
        hook_payload = payload || params[:payload]
        %w[password token].each { |key| hook_data[key] &&= '<redacted>' }
        owner = hook_payload['repository']['owner']['name'] rescue nil
        repo  = hook_payload['repository']['name'] rescue nil
        report_exception boom,
          :hook_name    => name,
          :hook_data    => hook_data.inspect,
          :hook_payload => hook_payload.inspect,
          :user         => owner,
          :repo         => "#{owner}/#{repo}"

        status 500
        "ERROR"
      end
    end
  end

  def parse_payload(json)
    payload = JSON.parse(json)
    payload['ref_name'] = payload['ref'].to_s.sub(/\Arefs\/(heads|tags)\//, '')
    payload
  end

  def shorten_url(url)
    Timeout::timeout(6) do
      short = Net::HTTP.get("api.bit.ly", "/shorten?version=2.0.1&longUrl=#{url}&login=github&apiKey=R_261d14760f4938f0cda9bea984b212e4")
      short = JSON.parse(short)
      short["errorCode"].zero? ? short["results"][url]["shortUrl"] : url
    end
  rescue Timeout::Error
    url
  end

  def report_exception(exception, other)
    # run only in github's production environment
    return if HOSTNAME != 'sh1.rs.github.com'

    backtrace = Array(exception.backtrace)[0..500]

    data = {
      'type'      => 'exception',
      'class'     => exception.class.to_s,
      'server'    => HOSTNAME,
      'message'   => exception.message[0..254],
      'backtrace' => backtrace.join("\n"),
      'rollup'    => Digest::MD5.hexdigest(exception.class.to_s + backtrace[0])
    }

    if exception.kind_of?(GitHub::ServiceError)
      if exception.original_exception
        data['original_class'] = exception.original_exception.to_s
        data['backtrace'] = exception.original_exception.backtrace.join("\n")
        data['message'] = exception.original_exception.message[0..254]
      end
    elsif !exception.kind_of?(GitHub::ServiceTimeout)
      data['original_class'] = data['class']
      data['class'] = 'GitHub::ServiceError'
    end

    # optional
    other.each { |key, value| data[key.to_s] = value.to_s }

    Net::HTTP.new('aux1', 9292).
      post('/haystack/async', "json=#{Rack::Utils.escape(data.to_json)}")
  rescue => boom
    $stderr.puts "reporting exception failed:"
    $stderr.puts "#{boom.class}: #{boom}"
    # swallow errors
  end
end
include GitHub

get "/" do
  "ok"
end

Dir["#{File.dirname(__FILE__)}/services/**/*.rb"].each { |service| load service }
