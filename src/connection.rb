require 'celluloid'
require 'net/http'
require 'uri'
require_relative './cache'

class ProxyConnectionHandler
  include Celluloid
  include Celluloid::Logger
  finalizer :on_close
  attr_reader :connection, :server

  def initialize(connection, server)
    @timer = after(30){  terminate }
    @connection = connection
    @server = server
    @target = server.target
    async.run
  end

  def on_close
    @connection.close
  end

  def run
    @connection.each_request { |req| @timer.reset; handle_request(req) }
  end

  def expired?(res)
    res['Expires'] && Time.parse(res['Expires']).past?
  end

  def revalidate(uri, force=false)
    uri = URI(uri) if uri.is_a?(String)
    debug "revalidating #{uri}"
    cache = Cache.read(uri.to_s)
    headers = {}
    if cache
      return if !force and expired?(cache)
      headers['If-None-Match'] = cache['Etag']
      headers['If-Modified-Since'] = cache['Last-Modified'] || cache['Date']
    end
    headers.delete_if { |k, v| v.nil? }
    Net::HTTP.start uri.host, uri.port do |http|
      store(uri.to_s, http.request_get(uri, headers))
    end
  end

  def store url, res
    server.async.store url, res
  end

  def pass(request)
    request.headers['Host'] = "#{@target.host}:#{@target.port||80}"
    request.headers.delete 'Accept-Encoding'
    Net::HTTP.start @target.host, @target.port || 80 do |http|
      http.send_request request.method, request.url, request.body.to_s, request.headers
    end
  end

  def handle_request(request)
    uri = request.uri.dup
    uri.scheme ||= @target.scheme
    uri.host ||= @target.host
    url = uri.to_s
    debug url
    if request.method == 'GET'
      if upres = Cache.read(url) and upres.is_a?(Net::HTTPResponse)
        debug 'hit'
        async.revalidate(url)
      else
        debug 'miss'
        request.headers.delete 'If-Modified-Since'
        request.headers.delete 'If-None-Match'
        upres = pass(request)
        store(url, upres)
      end
    else
      upres = pass(request)
    end

    h = {}
    upres.each_header do |key, val|
      h[key]=val
    end
    h.delete "transfer-encoding"
    res = Reel::Response.new(upres.code.to_i, h, upres.body)
    request.respond res
  end
end