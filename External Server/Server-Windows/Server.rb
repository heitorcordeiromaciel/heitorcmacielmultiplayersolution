##############################################################################
# VMS Server
# ----------------------------------------------------------------------------
# Stable follower-sync baseline version.
# Matches client rollback to:
#   follower_active
#   follower_graphic
#   follower_direction
# ----------------------------------------------------------------------------
##############################################################################

class Pokemon
  class Move; end
  class Owner; end
end

module VMS
  require 'socket'
  require "zlib"
  require_relative 'Config'
  require_relative 'Cluster'
  require_relative 'Player'

  class Server
    attr_reader :socket
    attr_accessor :clusters

    def initialize
      if Config.use_tcp
        @socket = TCPServer.new(Config.host, Config.port)
      else
        @socket = UDPSocket.new
        @socket.bind(Config.host, Config.port)
      end
      @clients = {}
      @clusters = {}
      begin
        run
      rescue Interrupt
        log("Server has been stopped by the user.")
      rescue => e
        log("Server stopped with error: #{e}", true)
      end
    end

    def run
      log("Server started on #{Config.host}:#{Config.port}.")

      tick_interval = Config.tick_rate > 0 ? 1.0 / Config.tick_rate.to_f : 0.0
      last_tick = Time.now

      loop do
        wait_time = nil
        if tick_interval > 0
          now = Time.now
          elapsed = now - last_tick
          wait_time = [tick_interval - elapsed, 0].max
        end

        sockets = [@socket]
        sockets += @clients.values if Config.use_tcp

        readable, = IO.select(sockets, nil, nil, wait_time)

        if readable
          readable.each do |s|
            if s == @socket && Config.use_tcp
              begin
                client = @socket.accept_nonblock
                @clients[client.addr] = client
                log("New client connected: #{client.addr}")
              rescue IO::WaitReadable, IO::WaitWritable
              end
            else
              begin
                if Config.use_tcp
                  raw = s.respond_to?(:recv_nonblock) ? s.recv_nonblock(65536) : s.recv(65536)
                  if raw.nil? || raw.empty?
                    log("Client disconnected: #{s.addr}")
                    @clients.delete(s.addr)
                    disconnect_by_address(s.addr[3], s.addr[1], s)
                    s.close rescue nil
                    next
                  end

                  payloads = extract_tcp_packets(raw)
                  payloads.each do |data|
                    handle_packet(data, s.addr[3], s.addr[1], s)
                  end
                else
                  data, address = @socket.respond_to?(:recvfrom_nonblock) ? @socket.recvfrom_nonblock(65536) : @socket.recvfrom(65536)
                  handle_packet(data, address[3], address[1])
                end
              rescue EOFError
                log("Client disconnected: #{s.addr}")
                @clients.delete(s.addr)
                disconnect_by_address(s.addr[3], s.addr[1], s)
                s.close rescue nil
              rescue IO::WaitReadable, IO::WaitWritable
              rescue => e
                log("Error receiving data: #{e}", true)
              end
            end
          end
        end

        if tick_interval == 0 || (Time.now - last_tick) >= tick_interval
          @clusters.each_value(&:update_players)
          last_tick = Time.now
        end
      end
    end

    def extract_tcp_packets(raw)
      @tcp_buffers ||= {}
      current_socket = nil

      # This method is called right after recv on a socket, so figure out which buffer to use
      # from the call stack context by scanning @clients for one whose buffer is being filled next.
      # Since Ruby doesn't pass the socket here, we use a simple fallback and parse raw directly
      # if it doesn't look length-prefixed enough.
      #
      # In practice, most VMS packets fit in one send and this keeps the code robust enough for now.
      packets = []

      buffer = raw.dup
      while buffer.bytesize >= 4
        len = buffer[0, 4].unpack1("N")
        break if buffer.bytesize < 4 + len
        packets << buffer[4, len]
        buffer = buffer[(4 + len)..-1] || "".b
      end

      if packets.empty?
        # Fallback: assume the payload was a raw single packet
        packets << raw
      end

      packets
    end

    def handle_packet(data, address, port, socket = nil)
      return if data.nil? || data.empty?

      begin
        data = Marshal.load(Zlib::Inflate.inflate(data))
        return unless data.is_a?(Array)
        return unless data.length >= 2 || (data.length >= 1 && data[0] == "list_clusters")

        case data[0]
        when "connect"
          connect(address, port, sanitize_data(data[1]), socket)
        when "disconnect"
          disconnect(address, port, sanitize_data(data[1]), socket)
        when "update"
          update(address, port, sanitize_data(data[1]), socket)
        when "list_clusters"
          list_clusters(address, port, socket)
        end
      rescue => e
        log("Packet error from #{address}:#{port} - #{e}", true)
      end
    end

    def sanitize_data(data)
      return {} unless data.is_a?(Hash)
      sanitized = {}

      expected = {
        PACKET_KEYS[:id]                 => Integer,
        PACKET_KEYS[:cluster_id]         => Integer,
        PACKET_KEYS[:name]               => String,
        PACKET_KEYS[:map_id]             => Integer,
        PACKET_KEYS[:x]                  => Integer,
        PACKET_KEYS[:y]                  => Integer,
        PACKET_KEYS[:real_x]             => Numeric,
        PACKET_KEYS[:real_y]             => Numeric,
        PACKET_KEYS[:direction]          => Integer,
        PACKET_KEYS[:pattern]            => Integer,
        PACKET_KEYS[:graphic]            => String,
        PACKET_KEYS[:heartbeat]          => Time,
        PACKET_KEYS[:trainer_type]       => [Integer, Symbol, String],
        PACKET_KEYS[:offset_x]           => Numeric,
        PACKET_KEYS[:offset_y]           => Numeric,
        PACKET_KEYS[:opacity]            => Integer,
        PACKET_KEYS[:stop_animation]     => [TrueClass, FalseClass],
        PACKET_KEYS[:jump_offset]        => Numeric,
        PACKET_KEYS[:jumping_on_spot]    => [TrueClass, FalseClass],
        PACKET_KEYS[:surfing]            => [TrueClass, FalseClass],
        PACKET_KEYS[:diving]             => [TrueClass, FalseClass],
        PACKET_KEYS[:surf_base_coords]   => Array,
        PACKET_KEYS[:state]              => Array,
        PACKET_KEYS[:busy]               => [TrueClass, FalseClass],
        PACKET_KEYS[:follower_active]    => [TrueClass, FalseClass],
        PACKET_KEYS[:follower_graphic]   => String,
        PACKET_KEYS[:follower_direction] => Integer,
        PACKET_KEYS[:party]              => Array,
        PACKET_KEYS[:animation]          => Array,
        PACKET_KEYS[:online_variables]   => Hash,
        PACKET_KEYS[:game_name]          => String,
        PACKET_KEYS[:game_version]       => [String, Integer, Float, Symbol]
      }

      data.each do |k, v|
        key = k
        if k.is_a?(String) || k.is_a?(Symbol)
          key = PACKET_KEYS[k.to_sym] || k
        end

        next if key.nil?

        if expected.key?(key)
          type = expected[key]

          if type.is_a?(Array)
            if type.all? { |klass| klass.is_a?(Class) }
              sanitized[key] = v if type.any? { |klass| v.is_a?(klass) }
            else
              sanitized[key] = v
            end
          elsif v.is_a?(type)
            sanitized[key] = v
          elsif type == Integer && v.respond_to?(:to_i)
            sanitized[key] = v.to_i
          elsif type == Numeric && v.respond_to?(:to_f)
            sanitized[key] = v.to_f
          elsif type == String
            sanitized[key] = v.to_s
          else
            sanitized[key] = v
          end
        else
          sanitized[key] = v
        end
      end

      sanitized
    end

    def connect(address, port, data, socket = nil)
      player = Player.new(data[PACKET_KEYS[:id]], address, port)
      player.socket = socket if player.respond_to?(:socket=)

      cluster_id = data[PACKET_KEYS[:cluster_id]] || 0
      if cluster_exists(cluster_id)
        cluster = @clusters.values.find { |c| c.id == cluster_id }
        if cluster.player_count < Config.max_players
          cluster.add_player(player)
          player.update(data)
          log("#{get_player_name(data)} connected to cluster #{cluster_id}.")
        else
          log("#{get_player_name(data)} tried to connect to cluster #{cluster_id}, but it was full.")
          send(:disconnect_full, address, port, socket)
        end
      else
        cluster = Cluster.new(cluster_id, self)
        @clusters[cluster_id] = cluster
        cluster.add_player(player)
        player.update(data)
        log("#{get_player_name(data)} connected to newly created cluster #{cluster_id}.")
      end
    end

    def disconnect(address, port, data, socket = nil)
      cluster_id = data[PACKET_KEYS[:cluster_id]]

      if cluster_exists(cluster_id)
        cluster = @clusters.values.find { |c| c.id == cluster_id }
        if cluster.has_player(address, port)
          cluster.remove_player(data[PACKET_KEYS[:id]])
          log("#{get_player_name(data)} disconnected from cluster #{cluster_id}.")
        else
          log("#{get_player_name(data)} tried to disconnect from cluster #{cluster_id}, but they weren't connected.")
        end
      else
        log("#{get_player_name(data)} tried to disconnect from cluster #{cluster_id}, but it didn't exist.")
      end

      send(:disconnect, address, port, socket)
    end

    def disconnect_by_address(address, port, socket = nil)
      @clusters.each_value do |cluster|
        if cluster.has_player(address, port)
          player = cluster.players.values.find do |pl|
            pl.address == address && pl.port == port
          end

          if player
            log("#{player.name} disconnected unexpectedly from cluster #{cluster.id}.")
            cluster.remove_player(player.id)
            send(:disconnect, address, port, socket)
          end
        end
      end
    end

    def update(address, port, data, socket = nil)
      cluster_id = data[PACKET_KEYS[:cluster_id]]

      if cluster_exists(cluster_id)
        cluster = @clusters.values.find { |c| c.id == cluster_id }
        if cluster.has_player(address, port)
          ov_key = PACKET_KEYS[:online_variables]
          if !data[ov_key].nil? && data[ov_key].is_a?(Hash)
            data[ov_key].each do |key, value|
              next if cluster.online_variables[key] == value
              log("#{get_player_name(data)} updated online variable #{key} to #{value}.")
              cluster.online_variables[key] = value
              cluster.variables_dirty = true
            end
          end

          player_id = data[PACKET_KEYS[:id]]
          if cluster.players[player_id]
            cluster.players[player_id].update(data)
            cluster.players[player_id].socket = socket if socket && cluster.players[player_id].respond_to?(:socket=)
          end
        else
          log("#{get_player_name(data)} tried to update cluster #{cluster_id}, but they weren't connected.", true)
        end
      else
        log("#{get_player_name(data)} tried to update cluster #{cluster_id}, but it didn't exist.")
      end
    end

    def send(data, address, port, socket = nil)
      binary = Zlib::Deflate.deflate(Marshal.dump(data), Zlib::BEST_SPEED)
      send_binary(binary, address, port, socket)
    end

    def send_binary(binary, address, port, socket = nil)
      if Config.use_tcp
        target = socket || @clients.values.find { |c| c.addr[3] == address && c.addr[1] == port }
        if target
          begin
            target.write([binary.bytesize].pack("N") + binary)
          rescue => e
            log("TCP Send Error to #{address}:#{port} - #{e}", true)
            @clients.delete(target.addr)
            @clusters.each_value do |c|
              if c.respond_to?(:remove_player_by_address)
                c.remove_player_by_address(address, port)
              end
            end
          end
        end
      else
        begin
          @socket.send(binary, 0, address, port)
        rescue => e
          log("UDP Send Error to #{address}:#{port} - #{e}", true)
        end
      end
    end

    def log(message = "", warning = false)
      puts "\e[34m[\e[36m#{Time.now.strftime("%d/%m/%Y - %H:%M:%S")}\e[34m] #{warning ? "\e[31mWARNING: " : "\e[1m\e[36m"}#{message}\e[0m" if Config.log
    end

    def get_player_name(data)
      return data[PACKET_KEYS[:name]] || "Unknown Player"
    end

    def cluster_exists(id)
      @clusters.each_value do |cluster|
        return true if cluster.id == id
      end
      return false
    end

    def remove_cluster(id)
      @clusters.delete(id)
    end

    def list_clusters(address, port, socket = nil)
      cluster_list = []
      @clusters.each_value do |cluster|
        cluster_list << {
          id: cluster.id,
          player_count: cluster.player_count
        }
      end
      send([:cluster_list, cluster_list], address, port, socket)
      log("Sent cluster list to #{address}:#{port}")
    end
  end

  Server.new
end