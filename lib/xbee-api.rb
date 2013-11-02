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
      length_h = data.length & 0xFF
      length_l = (data.length >> 8) & 0xFF
      print "Writing command: 0x7e 0x#{length_l.to_s(16)} 0x#{length_h.to_s(16)} [ "
      data.map {|byte| print "0x#{byte.ord.to_s(16)} "}
      puts "] 0x#{checksum.to_s(16)}"
      @port.write 0x7E
      @port.write length_l
      @port.write length_h
      data.map {|byte| @port.write byte}
      @port.write checksum
    end
    
    def at_command(at_cmd)
      cmd_pkt = [0x08, 0x01]
      at_cmd.split(//).map {|byte| cmd_pkt.push byte}
      send_packet cmd_pkt
      return @port.read
    end
    
    def node_identifier
      at_command('NI');
    end
  end
end