#!/usr/bin/ruby -w

require 'rubygems'
require 'serialport'

class ChecksumError < IOError
end

class IOPinDisabledError < IOError
end

class ATCommandError < IOError
end

class ATCommandInvalidError < ATCommandError
end

class ATCommandParameterInvalidError < ATCommandError
end

class ATCommandTxFailureError < ATCommandError
end

module XBee
  class Node
    attr_accessor :node_address, :identifier, :parent_addr, :type, :profile_id, :mfg_id, :io_pin

    def initialize(xbee, node_address)
      @xbee = xbee
      @node_address = node_address
      
      @io_pin = []
      (0..12).each do |pin|
        @io_pin[pin] = XBee::IOPin.new xbee, pin, self
      end
    end
    
    def at_command(cmd, args = [])
      @xbee.remote_at_command @node_address, cmd, args
    end
  end
  
  class ATResponse
    attr_accessor :source_address, :source_net_address, :response
  end
  
  class Packet
    attr_accessor :source_address, :rssi, :pan_broadcast, :address_broadcast, :data
  end
  
  class IOPin
    def initialize(xbee, pin_nbr, node = nil)
      @xbee = xbee
      @pin_nbr = pin_nbr
      @node = node ? node : xbee
    end
    
    def value?
      io_sample = @node.at_command 'IS' # sample IO pins
      response = io_sample.response
      raise IOPinDisabledError if response.length < 2
      enabled_dio = response[1..2].unpack("B16")[0].reverse
      enabled_aio = response[3].unpack("B8")[0].reverse
      response.each_byte {|byte| print "0x#{byte.ord.to_s(16)} "}
      if(enabled_dio[@pin_nbr] == '1') then
        # pin is a digital input
        dio_values = response[4..5].unpack("B16")[0].reverse
        return dio_values[@pin_nbr].to_i
      elsif(enabled_aio[@pin_nbr] == '1') then
        # pin is an analog input
        analog_start = enabled_dio.include?("1") ? 6 : 4
        puts "Reading bytes starting at #{analog_start+@pin_nbr*2}"
        return response[(analog_start+@pin_nbr*2)+1].ord | (response[analog_start+@pin_nbr*2].ord << 8)
      else
        # pin is disabled
        raise IOPinDisabledError
      end
    end
    
    def pin_to_cmd(pin_nbr)
      case pin_nbr
        when 0..7
          "D#{@pin_nbr}"
        when 10
          "P0"
        when 11
          "P1"
        when 12
          "P2"
      end
    end

    def digital_in!
      @node.at_command pin_to_cmd(@pin_nbr), [0x03]  # monitored digital input
      @node.at_command "AC" # apply changes
    end
    
    def analog_in!
      @node.at_command pin_to_cmd(@pin_nbr), [0x02]  # single-ended analog input
      @node.at_command "AC" #apply changes
    end
  end
  
  class API
    attr_accessor :io_pin

    def initialize(port, speed)
      @port = SerialPort.new port, speed
      @io_pin = []
      (0..12).each do |pin|
        @io_pin[pin] = XBee::IOPin.new self, pin
      end
      @nodes = Hash.new
    end
    
    def send_packet(data)
      checksum = 0
      data.map {|byte| checksum += byte.ord}
      checksum = 0xFF - (checksum & 0xFF)
      @port.write [ 0x7E, data.count, data.map {|b| b.kind_of?(String) ? b.ord : b}, checksum ].flatten.pack("CnC#{data.count}C")
      #[ 0x7E, data.count, data.map {|b| b.kind_of?(String) ? b.ord : b}, checksum ].flatten.pack("CnC#{data.count}C").each_char {|b| print "0x#{b.ord.to_s(16)} "}
    end
    
    def get_response(start_byte = nil)
      # if we're called from get_response_nonblock, the start byte has already been read/passed to us
      # otherwise read it here
      if(!start_byte) then
        start_byte = @port.read(1)
      end
      while(start_byte.ord != 0x7E) do
        puts "Received junk data before start byte"
      end
      length = @port.read(2).unpack('n')[0]
      data = @port.read(length)
      checksum = @port.read(1).ord
      data.each_byte {|byte| checksum += byte.ord}
      checksum &= 0xFF
      raise ChecksumError if checksum != 0xFF
      return data
    end

    def get_response_nonblock
      begin
        start_byte = @port.read_nonblock(1)
      rescue Errno::EAGAIN
        return nil
      end
      get_response start_byte
    end
    
    def get_at_response
      response = get_response[4..-1]  # trim the frame identifier and command itself off
      #response.each_byte {|byte| print "0x#{byte.ord.to_s(16)}[#{byte.chr}] "}
      status = response[0].ord.to_i
      check_status status
      response[1..-1]
    end
    
    def get_remote_at_response
      response = get_response[2..-1]  # trim the frame identifier and type off
      (source_addr, source_net_addr, at_cmd, status, data) = response.unpack("Q>na2Ca*")
      #response.each_byte {|byte| print "0x#{byte.ord.to_s(16)}[#{byte.chr}] "}
      check_status status
      at_cmd = at_cmd # TODO: either use this or don't collect it
      respobj = XBee::ATResponse.new
      respobj.source_address = source_addr
      respobj.source_net_address = source_net_addr
      respobj.response = data
      respobj
    end
    
    def check_status(status)
      case status
        when 0x01
          raise ATCommandError
        when 0x02
          raise ATCommandInvalidError
        when 0x03
          raise ATCommandParameterInvalidError
        when 0x04
          raise ATCommandTxFailureError
      end
    end
    
    def node(node_address)
      return @nodes[node_address] if @nodes[node_address]
      @nodes[node_address] = XBee::Node.new self, node_address
    end
    
    def parse_node_response(response)
      (node_address, identifier, parent_addr, type, profile_id, mfg_id) = response.unpack("xxQ>Z*nCxnn")
      node = XBee::Node.new(self, node_address)
      node.identifier = identifier
      node.parent_addr = parent_addr == 0xFFFE ? nil : parent_addr  # 0xFFFE = "no parent"
      node.type = case type
        when 0
          :coordinator
        when 1
          :router
        when 2
          :end_device
      end
      node.profile_id = profile_id
      node.mfg_id = mfg_id
      node
    end
    
    def parse_rx_packet_response(response)
      (frame_type, source_addr, rssi, options, data) = response.unpack("CQCCa*")
      raise IOError if frame_type != 0x80
      pkt = XBee::Packet.new
      pkt.source_address = source_addr
      pkt.rssi = rssi
      pkt.pan_broadcast = (options & 0x4 == 0 ? false : true)
      pkt.address_broadcast = (options & 0x2 == 0 ? false : true)
      pkt.data = data
      pkt
    end
    
    def at_command(at_cmd, args = [])
      cmd_pkt = [0x08, 0x01]  # type: local AT command, frame ID: 1
      at_cmd.each_byte {|byte| cmd_pkt.push byte}
      cmd_pkt.push args
      send_packet cmd_pkt.flatten
      respobj = XBee::ATResponse.new
      respobj.response = get_at_response
      respobj
    end
    
    def remote_at_command(remote_serial, at_cmd, args = [])
      cmd_pkt = [0x17, 0x01]  # type: remote AT command, frame ID: 1
      cmd_pkt.push remote_serial >> 56 & 0xFF  # FIXME: must be an easier way...
      cmd_pkt.push remote_serial >> 48 & 0xFF
      cmd_pkt.push remote_serial >> 40 & 0xFF
      cmd_pkt.push remote_serial >> 32 & 0xFF
      cmd_pkt.push remote_serial >> 24 & 0xFF
      cmd_pkt.push remote_serial >> 16 & 0xFF
      cmd_pkt.push remote_serial >> 8 & 0xFF
      cmd_pkt.push remote_serial >> 0 & 0xFF
      cmd_pkt.push 0xFF # FIXME: support specifying network addresses
      cmd_pkt.push 0xFE # FIXME: --^
      cmd_pkt.push 0x00
      at_cmd.each_byte {|byte| cmd_pkt.push byte}
      cmd_pkt.push args
      send_packet cmd_pkt.flatten
      get_remote_at_response      
    end
    
    def node_identifier
      at_command 'NI'
    end
    
    def node_discovery_timeout
      (at_command('NT').response[1].ord*100).to_i # FIXME: why is the first byte always 0?
    end
    
    def nodes
      timeout = node_discovery_timeout
      nodes = []
      nodes.push parse_node_response(at_command('ND').response)
      while(IO.select([@port], [], [], timeout/1000) != nil)
        response = parse_node_response(get_at_response)
        nodes.push response
      end
      nodes
    end
    
    def each_packet
      while(true) do
        response = get_response_nonblock
        break if !response
        packet = parse_rx_packet_response(response)
        yield packet
      end
    end
  end
end
