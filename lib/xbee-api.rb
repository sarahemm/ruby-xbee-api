#!/usr/bin/ruby -w

require 'rubygems'
require 'serialport'

module XBee
  class API
    def initialize(port, speed)
      @port = SerialPort.new port, :baud => speed
    end
    
    def send_packet(data)
      checksum = 0
      data.map {|byte| checksum += byte.ord}
      checksum = 0xFF - (checksum & 0xFF)
      @port.write [ 0x7E, data.count, data.map {|b| b.kind_of?(String) ? b.ord : b}, checksum ].flatten.pack("CnC#{data.count}C")
      [ 0x7E, data.count, data.map {|b| b.kind_of?(String) ? b.ord : b}, checksum ].flatten.pack("CnC#{data.count}C").each_char {|b| print "0x#{b.ord.to_s(16)} "}
    end
    
    def at_command(at_cmd)
      cmd_pkt = [0x08, 0x01]
      at_cmd.split(//).map {|byte| cmd_pkt.push byte}
      send_packet cmd_pkt
      return @port.read 1
    end
    
    def node_identifier
      at_command('NI');
    end
  end
end
