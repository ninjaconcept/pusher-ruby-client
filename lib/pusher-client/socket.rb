require 'json'
require 'hmac-sha2'
require 'digest/md5'

module PusherClient
  class Socket

    # Mimick the JavaScript client
    CLIENT_ID = 'pusher-ruby-client'
    VERSION = '0.2.2'
    PROTOCOL = '5'

    attr_accessor :encrypted, :secure
    attr_reader :path, :connected, :channels, :global_channel, :socket_id

    def initialize(application_key, options={})
      raise ArgumentError if (!application_key.is_a?(String) || application_key.size < 1)

      @path = "/app/#{application_key}?client=#{CLIENT_ID}&version=#{VERSION}&protocol=#{PROTOCOL}"
      @key = application_key
      @secret = options[:secret]
      @socket_id = nil
      @channels = Channels.new
      @global_channel = Channel.new('pusher_global_channel')
      @global_channel.global = true
      @secure = false
      @connected = false
      @encrypted = options[:encrypted] || false

      bind('pusher:connection_established') do |data|
        socket = Hash === data ? data : JSON.parse(data) #data is a Hash when using with Slanger
        @connected = true
        @socket_id = socket['socket_id']
        subscribe_all
      end

      bind('pusher:connection_disconnected') do |data|
        @channels.channels.each { |c| c.disconnect }
      end

      bind('pusher:error') do |data|
        PusherClient.logger.fatal("Pusher : error : #{data.inspect}")
      end

      # Keep this in case we're using a websocket protocol that doesn't
      # implement ping/pong
      bind('pusher:ping') do
        send_event('pusher:pong', nil)
      end
    end

    def connect(async = false)
      if @encrypted || @secure
        url = "wss://#{PusherClient.host}:#{PusherClient.wss_port}#{@path}"
      else
        url = "ws://#{PusherClient.host}:#{PusherClient.ws_port}#{@path}"
      end
      PusherClient.logger.debug("Pusher : connecting : #{url}")

      @connection_thread = Thread.new {
        options = {:ssl => @encrypted || @secure}
        @connection = PusherWebSocket.new(url, options)
        PusherClient.logger.debug "Websocket connected"
        loop do
          msg = @connection.receive[0]
          next if msg.nil?
          params  = parser(msg)
          next if (params['socket_id'] && params['socket_id'] == self.socket_id)
          event_name   = params['event']
          event_data   = params['data']
          channel_name = params['channel']
          send_local_event(event_name, event_data, channel_name)
        end
      }

      @connection_thread.run
      @connection_thread.join unless async
      return self
    end

    def disconnect
      if @connected
        PusherClient.logger.debug "Pusher : disconnecting"
        @connection.close
        @connection_thread.kill if @connection_thread
        @connected = false
      else
        PusherClient.logger.warn "Disconnect attempted... not connected"
      end
    end

    def subscribe(channel_name, user_id = nil, user_info = nil)
      user_data = {}
      user_data.merge!(:user_id => user_id) unless user_id.nil?
      user_data.merge!(:user_info => user_info) unless user_info.nil?
      @user_data = user_data.to_json

      channel = @channels << channel_name
      if @connected
        authorize(channel, method(:authorize_callback))
      end
      return channel
    end

    def unsubscribe(channel_name)
      channel = @channels.remove channel_name
      if @connected
        send_event('pusher:unsubscribe', {
          'channel' => channel_name
        })
      end
      return channel
    end

    def bind(event_name, &callback)
      @global_channel.bind(event_name, &callback)
      return self
    end

    def [](channel_name)
      if @channels[channel_name]
        @channels[channel_name]
      else
        @channels << channel_name
      end
    end

    def subscribe_all
      @channels.channels.clone.each{ |k,v|
        subscribe(k)
      }
    end

    #auth for private and presence
    def authorize(channel, callback)
      if is_private_channel(channel.name)
        auth_data = get_private_auth(channel)
      elsif is_presence_channel(channel.name)
        auth_data = get_presence_auth(channel)
        channel_data = @user_data
      end
      # could both be nil if didn't require auth
      callback.call(channel, auth_data, channel_data)
    end

    def authorize_callback(channel, auth_data, channel_data)
      send_event('pusher:subscribe', {
        'channel' => channel.name,
        'auth' => auth_data,
        'channel_data' => channel_data
      })
      channel.acknowledge_subscription(nil)
    end

    def is_private_channel(channel_name)
      channel_name.match(/^private-/)
    end

    def is_presence_channel(channel_name)
      channel_name.match(/^presence-/)
    end

    def get_private_auth(channel)
      string_to_sign = @socket_id + ':' + channel.name
      signature = HMAC::SHA256.hexdigest(@secret, string_to_sign)
      return "#{@key}:#{signature}"
    end

    def get_presence_auth(channel)
      string_to_sign = @socket_id + ':' + channel.name + ':' + @user_data
      signature = HMAC::SHA256.hexdigest(@secret, string_to_sign)
      return "#{@key}:#{signature}"
    end


    # For compatibility with JavaScript client API
    alias :subscribeAll :subscribe_all

    def send_event(event_name, data)
      payload = {'event' => event_name, 'data' => data}.to_json
      @connection.send(payload)
      PusherClient.logger.debug("Pusher : sending event : #{payload}")
    end

  protected

    def send_local_event(event_name, event_data, channel_name)
      if (channel_name)
        channel = @channels[channel_name]
        if (channel)
          channel.dispatch_with_all(event_name, event_data)
        end
      end

      @global_channel.dispatch_with_all(event_name, event_data)
      PusherClient.logger.debug("Pusher : event received : channel: #{channel_name}; event: #{event_name}")
    end

    def parser(data)
      begin
        return JSON.parse(data)
      rescue => err
        PusherClient.logger.warn(err)
        PusherClient.logger.warn("Pusher : data attribute not valid JSON - you may wish to implement your own Pusher::Client.parser")
        return data
      end
    end
  end

end
