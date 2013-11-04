#!/usr/bin/ruby -w

require 'rubygems'
require 'serialport'

class ChecksumError < IOError
end

class IOPinDisabledError < IOError
end

class ATCommandError < IOError
end

module XBee
  class Node
    attr_accessor :serial, :identifier, :parent_addr, :type, :profile_id, :mfg_id
  end
  
  class IOPin
    def initialize(xbee, pin_nbr)
      @xbee = xbee
      @pin_nbr = pin_nbr
    end
    
    def value?
      io_sample = @xbee.at_command 'IS' # sample IO pins
      raise IOPinDisabledError if io_sample.length < 2
      enabled_dio = io_sample[1..2].unpack("B16")[0].reverse
      #enabled_aio = io_sample[3].unpack("B8")[0].reverse
      raise IOPinDisabledError if enabled_dio[@pin_nbr] == '0'
      dio_values = io_sample[4..5].unpack("B16")[0].reverse
      return dio_values[@pin_nbr].to_i
    end
    
    def digital_in!
      cmd = ""
      case @pin_nbr
        when 0..7
          cmd = "D#{@pin_nbr}"
        when 10
          cmd = "P0"
        when 11
          cmd = "P1"
        when 12
          cmd = "P2"
      end
      @xbee.at_command cmd, [0x03]
      @xbee.at_command "AC" # apply changes
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
    end
    
    def send_packet(data)
      checksum = 0
      data.map {|byte| checksum += byte.ord}
      checksum = 0xFF - (checksum & 0xFF)
      @port.write [ 0x7E, data.count, data.map {|b| b.kind_of?(String) ? b.ord : b}, checksum ].flatten.pack("CnC#{data.count}C")
      #[ 0x7E, data.count, data.map {|b| b.kind_of?(String) ? b.ord : b}, checksum ].flatten.pack("CnC#{data.count}C").each_char {|b| print "0x#{b.ord.to_s(16)} "}
    end
    
    def get_response
      while(@port.read(1).ord != 0x7E) do
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
    
    def get_at_response
      response = get_response[4..-1]  # trim the frame identifier and command itself off
      status = response[0].to_i
      raise ATCommandError if status != 0x00
      response[1..-1]
    end
    
    def parse_node_response(response)
      (serial, identifier, parent_addr, type, profile_id, mfg_id) = response.unpack("xxQZ*nxnn")
      node = XBee::Node.new
      node.serial = serial
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
    
    def at_command(at_cmd, args = [])
      cmd_pkt = [0x08, 0x01]
      at_cmd.each_byte {|byte| cmd_pkt.push byte}
      cmd_pkt.push args
      send_packet cmd_pkt.flatten
      get_at_response
    end
    
    def node_identifier
      at_command 'NI'
    end
    
    def node_discovery_timeout
      (at_command('NT')[1].ord*100).to_i # FIXME: why is the first byte always 0?
    end
    
    def nodes
      timeout = node_discovery_timeout
      nodes = []
      nodes.push parse_node_response(at_command('ND'))
      while(IO.select([@port], [], [], timeout/1000) != nil)
        response = parse_node_response(get_at_response)
        nodes.push response
      end
      p nodes
    end
  end
end
