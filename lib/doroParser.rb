#!/usr/local/bin/ruby
#$LOAD_PATH.unshift '/opt/local/lib/ruby/gems/1.8/gems/ruby-filemagic-0.4.2/lib'  #for MACOSX
$LOAD_PATH.unshift '/usr/lib/ruby/gems/1.8/gems/ruby-filemagic-0.4.2/lib'		  #for linux Debian
require 'rubygems'
require 'mu/xtractr'
require 'md5'
require 'rbvmomi'
require 'rest_client'

require 'net/dns/packet'
require 'ipaddr'
require 'colored'
require 'trollop'

require File.dirname(__FILE__) + '/dorothy/environment'
require File.dirname(__FILE__) + '/dorothy/do-parsers'
require File.dirname(__FILE__) + '/dorothy/do-utils'
require File.dirname(__FILE__) + '/dorothy/do-logger'


module DoroParser
#Host roles 

  CCIRC = 1
  CCDROP = 3
  CCSUPPORT = 5

  def search_irc(streamdata)

    util = Util.new


    ircvalues = []
    streamdata.each do |m|
      #	if m[1] == 0  #we fetch only outgoing traffic
      direction_bool = (m[1] == 0 ? false : true)
      LOGGER_PARSER.info "PARSER", "FOUND IRC DATA".white
      LOGGER_PARSER.info "IRC", "#{m[0]}".yellow
      #puts "..::: #{parsed.command}".white + " #{parsed.content}".yellow 

      ircvalues.push "default, currval('dorothy.connections_id_seq'), E'#{Insertdb.escape_bytea(m[0])}', #{direction_bool}"
      #	end
    end
    return ircvalues
  end

  def analyze_bintraffic(pcaps)

    dns_list = Hash.new
    hosts = []
    @insertdb.begin_t

    pcaps.each do |dump|
      #RETRIVE MALWARE FILE INFO

      !dump['sample'].nil? && !dump['hash'].nil? && !dump['pcapr_id'].nil? or next

      LOGGER_PARSER.info "PARSER", "Analyzing file: ".yellow + dump['sample']
      LOGGER_PARSER.info "PARSER", "Analyzing pcaprid: ".yellow + dump['pcapr_id'].gsub(/\s+/, "")


      LOGGER_PARSER.debug "PARSER", "Analyzing dump: ".yellow + dump['hash'].gsub(/\s+/, "") if VERBOSE


      #gets

      downloadir = "#{ANALYSIS_DIR}/#{dump['sample'].gsub(/\s+/, "")}/downloads"

      #puts "Sighting of #{malw.sha} imported"

      ##NETWORK DUMP PARSING#
      #######################
      #LOAD XTRACTR INSTANCE#

      #	begin
      #		t = RestClient.get "http://172.20.250.13:8080/pcaps/1/about/#{dump['pcapr_id'].gsub(/\s+/, "")"
      #		jt = JSON.parse(t)
      #		rescue RestClient::InternalServerError
      #		puts ".:: File not found: http://172.20.250.13:8080/pcaps/1/about/#{dump['pcapr_id'].gsub(/\s+/, "")".red
      #		puts ".:: #{$!}".red 
      ##		puts ".:: Skipping malware #{dump['hash']} and doing DB ROLLBACK".red
      #		next
      #	end

      #	puts ".:: File PCAP found on PCAPR DB - #{jt['filename']} - ID #{dump['pcapr_id'].gsub(/\s+/, "")"
      #xtractr = Mu::Xtractr.create "http://172.20.250.13:8080/home/index.html#/browse/pcap/dd737a00ff0495083cf6edd772fe2a18"
      # 843272e9a0b6a5f4aa5985d151cb6721

      begin
        #TEST!
        xtractr = Doroxtractr.create "http://172.20.250.13:8080/pcaps/1/pcap/#{dump['pcapr_id'].gsub(/\s+/, "")}"
        #xtractr = Doroxtractr.create "http://172.20.250.13:8080/pcaps/1/pcap/071dc8540a88d72c15d8542f6c7610f8"
          #puts "TEST MODE ON!"
          #gets

      rescue
        LOGGER_PARSER.fatal "PARSER", "Can't create a XTRACTR instance, try with nextone".red
      #  LOGGER_PARSER.debug "PARSER", "#{$!}"
        next
      end


      LOGGER_PARSER.info "PARSER", "Scanning network flows and searching for unknown host IPs".yellow

      #xtractr.flows('flow.service:HTTP').each  { |flow|

      xtractr.flows.each { |flow|
        #TODO: begin  , make exception hangling for every flow

        #DEBUG
        #puts flow.id

        flowdeep = xtractr.flows("flow.id:#{flow.id}")



        #Skipping if NETBIOS spreading activity:
        if flow.dport == 135 or flow.dport == 445
          LOGGER_PARSER.info "PARSER", "Netbios connections, skipping flow" unless NONETBIOS
          next
        end


        title = flow.title[0..200].gsub(/'/,"") #xtool bug ->')


        #insert hosts (geo) info into db
        #check if is a localaddress
        localip = "10.0.0.0"
        localnet = IPAddr.new("#{localip}/24")
        multicast = IPAddr.new("224.0.0.0/4")

        #check if already present in DB
        unless(@insertdb.select("host_ips", "ip", flow.dst.address).one? || hosts.include?(flow.dst.address))
          LOGGER_PARSER.info "PARSER", "Analyzing #{flow.dst.address}".yellow
          hosts << flow.dst.address
          dest = flow.dst.address


          #insert Geoinfo
          unless(localnet.include?(flow.dst.address) || multicast.include?(flow.dst.address))

            geo = Geoinfo.new(flow.dst.address.to_s)
            geoval = ["default", geo.coord, geo.country, geo.city, geo.updated, geo.asn]
            LOGGER_PARSER.debug "GEO", "Geo-values for #{flow.dst.address.to_s}: " + geo.country + " " + geo.city + " " + geo.coord if VERBOSE

            if geo.coord != "null"
              LOGGER_PARSER.debug "DB", " Inserting geo values for #{flow.dst.address.to_s} : #{geo.country}".blue  if VERBOSE
              @insertdb.insert("geoinfo",geoval)
              geoval = "currval('dorothy.geoinfo_id_seq')"
            else
              LOGGER_PARSER.warn "DB", " No Geovalues found for #{flow.dst.address.to_s}".red  if VERBOSE
              geoval = "null"
            end

          else
            LOGGER_PARSER.warn "PARSER", "#{flow.dst.address} skipped while searching for GeoInfo (it's a local network))".yellow
            geoval = 'null'
            dest = localip
          end

          #Insert host info
          #ip - geoinfo -  sbl - uptime - is_online - whois - zone - last-update - id - dns_name
          hostname = (dns_list[dest].nil? ? "null" : dns_list[dest])
          hostval = [dest, geoval, "null", "null", true, "null", "null", get_time, "default", hostname]

          if	!@insertdb.insert("host_ips",hostval)
            LOGGER_PARSER.debug "DB", " Skipping flow #{flow.id}: #{flow.src.address} > #{flow.dst.address}"  if VERBOSE
            next
          end

        else
          LOGGER_PARSER.debug "PARSER", "Host already #{flow.dst.address} known, skipping..." if VERBOSE
          #puts ".:: Geo info host #{flow.dst.address} already present in geodatabase, skipping.." if @insertdb.select("host_ips", "ip", flow.dst.address)
        end

        #case TCP xtractr.flows('flow.service:SMTP').first.proto = 6

        flowvals = [flow.src.address, flow.dst.address, flow.sport, flow.dport, flow.bytes, dump['hash'], flow.packets, "default", flow.proto, flow.service.name, title, "null", flow.duration, flow.time, flow.id ]

        if	!@insertdb.insert("flows",flowvals)
          LOGGER_PARSER.info "PARSER", "Skipping flow #{flow.id}: #{flow.src.address} > #{flow.dst.address}"
          next
        end

        LOGGER_PARSER.debug("DB", "Inserting flow #{flow.id} - #{flow.title}".blue) if VERBOSE

        flowid = "currval('dorothy.connections_id_seq')"

        #Layer 3 analysis
        service = flow.service.name

        #DEBUG
        #puts "PROTO = " + flow.proto.to_s

        case flow.proto
          when 6 then
            #check if HTTP,IRC, MAIL
            #xtractr.flows('flow.service:SMTP').first.service.name == "TCP" when unknow

            #Layer 4 analysis
            streamdata = xtractr.streamdata(flow.id)

            #DEBUG
            #puts "SERVICE = " + service.to_s

            case service  #TODO: don't trust service field: it's based on default-port definition, do a packet inspection instead.

              #case HTTP
              when "HTTP" then
                http = DoroHttp.new(flowdeep)

                if http.method =~ /GET|POST/
                  LOGGER_PARSER.info "HTTP", "FOUND an HTTP request".white
                  LOGGER_PARSER.info "HTTP", "HTTP #{http.method}".white + " #{http.uri}".yellow

                  t = http.uri.split('/')
                  filename = (t[t.length - 1].nil? ? "noname-#{flow.id}" :  t[t.length - 1])

                  if http.method =~ /POST/
                    role_values = [CCDROP, flow.dst.address]
                    @insertdb.insert("host_roles", role_values ) unless @insertdb.select("host_roles", "role", role_values[0], "host_ip", role_values[1]).one?
                    http.data = xtractr.flowcontent(flow.id)
                    LOGGER_PARSER.debug "DB", "POST DATA SAVED IN THE DB"
                  end

                  if http.contype =~ /application/     # STORING ONLY application* type GET DATA (avoid html pages, etc)
                    LOGGER_PARSER.info "HTTP", "FOUND an Application Type".white
                    LOGGER_PARSER.debug "DB", " Inserting #{filename} downloaded file info" if VERBOSE

                    #download	
                    flowdeep.each do |flow|
                      flow.contents.each do |c|

                        LOGGER_PARSER.debug("DB", "Inserting downloaded http file info from #{flow.dst.address.to_s}".blue) if VERBOSE

                        downvalues = [ DoroFile.sha2(c.body), flowid, downloadir, filename ]
                        @insertdb.insert("downloads", downvalues )

                        role_values = [CCSUPPORT, flow.dst.address]
                        @insertdb.insert("host_roles", role_values ) unless @insertdb.select("host_roles", "role", role_values[0], "host_ip", role_values[1]).one?

                        LOGGER_PARSER.debug "HTTP", "Saving downloaded file into #{downloadir}".white if VERBOSE
                        c.save("#{downloadir}/#{filename}")
                      end

                    end


                  end

                  httpvalues = "default, '#{http.method.downcase}', '#{http.uri}', #{http.size}, #{http.ssl}, #{flowid}, E'#{Insertdb.escape_bytea(http.data)}' "

                  LOGGER_PARSER.debug "DB", " Inserting http data info from #{flow.dst.address.to_s}".blue if VERBOSE
                  @insertdb.raw_insert("http_data", httpvalues)

                else
                  LOGGER_PARSER.warn "HTTP", "Not a regular HTTP traffic on flow #{flow.id}".yellow
                  LOGGER_PARSER.info "PARSER", "Trying to guess if it is IRC".white

                  if Parser.guess(streamdata.inspect).class.inspect =~ /IRC/
                    ircvalues = search_irc(streamdata)
                    ircvalues.each do |ircvalue|
                      LOGGER_PARSER.debug "DB", " Inserting IRC DATA info from #{flow.dst.address.to_s}".blue if VERBOSE
                      @insertdb.raw_insert("irc_data", ircvalue )
                      role_values = [CCIRC, flow.dst.address]
                      @insertdb.insert("host_roles", role_values ) unless @insertdb.select("host_roles", "role", role_values[0], "host_ip", role_values[1]).one?
                    end

                  else
                    LOGGER_PARSER.info "PARSER", "NO-IRC".red
                    #TODO, store UNKNOWN communication data 

                  end





                end

              #case MAIL
              when "SMTP" then
                LOGGER_PARSER.info "SMTP", "FOUND an SMTP request..".white
                #insert mail
                #by from to subject data id time connection


                streamdata.each do |m|
                  mailfrom = 'null'
                  mailto = 'null'
                  mailcontent = 'null'
                  mailsubject = 'null'
                  mailhcmd = 'null'
                  mailhcont = 'null'
                  rdata = ['null', 'null']

                  case m[1]
                    when 0
                      if Parser::SMTP.header?(m[0])
                        @email = Parser::SMTP.new(m[0])
                        LOGGER_PARSER.info "SMTP", "[A]".white + @email.hcmd + " " + @email.hcont
                        if Parser::SMTP.hasbody?(m[0])
                          @email.body = Parser::SMTP.body(m[0])
                          mailto = @email.body.to
                          mailfrom = @email.body.from
                          mailsubject = @email.body.subject.gsub(/'/,"") #xtool bug ->')
                        end
                      end
                    when 1
                      rdata = Parser::SMTP.response(m[0]) if Parser::SMTP.response(m[0])
                      LOGGER_PARSER.info "SMTP", "[R]".white + rdata[0] + " " + rdata[1]
                      rdata[0] = 'null' if rdata[0].empty?
                      rdata[1] = 'null' if rdata[1].empty?

                  end
                  mailvalues = [mailfrom, mailto, mailsubject, mailcontent, "default", flowid, mailhcmd, mailhcont, rdata[0], rdata[1].gsub(/'/,"")] #xtool bug ->')
                  @insertdb.insert("emails", mailvalues )
                end



              #case FTP
              when "FTP" then
                LOGGER_PARSER.info "FTP", "FOUND an FTP request".white
              #TODO
              when "TCP" then

                LOGGER_PARSER.info "TCP", "FOUND GENERIC TCP TRAFFIC - may be a netbios scan".white
                LOGGER_PARSER.info "PARSER", "Trying see if it is IRC traffic".white

                if Parser.guess(streamdata.inspect).class.inspect =~ /IRC/
                  ircvalues = search_irc(streamdata)
                  ircvalues.each do |ircvalue|
                    LOGGER_PARSER.debug "DB", " Inserting IRC DATA info from #{flow.dst.address.to_s}".blue if VERBOSE
                    @insertdb.raw_insert("irc_data", ircvalue )
                    role_values = [CCIRC, flow.dst.address]
                    @insertdb.insert("host_roles", role_values ) unless @insertdb.select("host_roles", "role", CCIRC, "host_ip", flow.dst.address).one?
                  end
                end


              else

                LOGGER_PARSER.info "PARSER", "Unknown traffic, try see if it is IRC traffic"

                if Parser.guess(streamdata.inspect).class.inspect =~ /IRC/
                  ircvalues = search_irc(streamdata)
                  ircvalues.each do |ircvalue|
                    LOGGER_PARSER.debug "DB", " Inserting IRC DATA info from #{flow.dst.address.to_s}".blue if VERBOSE
                    @insertdb.raw_insert("irc_data", ircvalue )
                    role_values = [CCIRC, flow.dst.address]
                    @insertdb.insert("host_roles", role_values ) unless @insertdb.select("host_roles", "role", CCIRC, "host_ip", flow.dst.address).one?
                  end
                end

            end

          when 17 then
            #check if DNS

            #Layer 4 analysis
            case service
              when "DNS" then
                #DEBUG
                #puts "DNS"

                @i = 0
                @p = []

                flowdeep.each  do |flow|
                  flow.each do |pkt|
                    @p[@i] = pkt.payload
                    @i = @i + 1
                  end
                end


                @p.each do |d|

                  begin

                    dns = DoroDNS.new(d)


                    dnsvalues = ["default", dns.name, dns.cls_i.inspect, dns.qry?, dns.ttl, flowid, dns.address.to_s, dns.data, dns.type_i.inspect]

                    LOGGER_PARSER.debug "DB", " Inserting DNS data from #{flow.dst.address.to_s}".blue if VERBOSE
                    unless @insertdb.insert("dns_data", dnsvalues )
                      LOGGER_PARSER.error "DB", " Error while Inserting DNS data".blue
                      nex
                    end
                    dnsid = @insertdb.find_seq("dns_id_seq").first['currval']

                    if dns.qry?
                      LOGGER_PARSER.info "DNS", "DNS Query:".white + "  #{dns.name}".yellow + "  class #{dns.cls_i} type #{dns.type_i}"
                    else
                      dns_list.merge!( dns.address.to_s => dnsid)
                      LOGGER_PARSER.info "DNS", "DNS Answer:".white + "  #{dns.name}".yellow + " class #{dns.cls} type #{dns.type} ttl #{dns.ttl} " + "#{dns.address}".yellow
                    end

                  rescue

                    LOGGER_PARSER.error "DB", "Something went wrong while adding a DNS entry into the DB (packet malformed?) - The packet will be skipped ::."
                    LOGGER_PARSER.debug "DB", "#{$!}"
                  end


                end
            end

          when 1 then
            #TODO: ICMP data
            #case ICMP xtractr.flows('flow.service:SMTP').first.proto = 1
          else

            LOGGER_PARSER.warn "PARSER", "Unknown protocol: #{flow.id}  -- Proto #{flow.proto}".yellow

        end


      }

      #DEBUG
      #puts "save?" 
      #gets
      @insertdb.set_analyzed(dump['hash'])
      @insertdb.commit
    end
  end


  def self.start(daemon)
    daemon ||= false

    puts "[DoroParser]".yellow +  " Started, tail log file to see some stuff.."
    LOGGER_PARSER.info "Dorothy", "Started".yellow

    if daemon
      check_pid_file PIDFILE_PARSER
      puts "[DoroParser]".yellow + " Going in backround with pid #{Process.pid}"
      Process.daemon
      create_pid_file PIDFILE_PARSER
      LOGGER_PARSER.info "DoroParser", "Going in backround with pid #{Process.pid}"
    end


    @insertdb = Insertdb.new
    infinite = true

    while infinite
      pcaps = @insertdb.find_pcap
      analyze_bintraffic pcaps
      infinite = daemon
      sleep DTIMEOUT if daemon # Sleeping a while if -d wasn't set, then quit.
    end
    LOGGER_PARSER.info "DoroParser" , "There are no more files to analyze.".yellow
    exit(0)
  end

  def check_pid_file file
    if File.exist? file
      # If we get Errno::ESRCH then process does not exist and
      # we can safely cleanup the pid file.
      pid = File.read(file).to_i
      begin
        Process.kill(0, pid)
      rescue Errno::ESRCH
        stale_pid = true
      rescue
      end

      unless stale_pid
        puts "[DoroParser]".yellow + " Dorothy is already running (pid=#{pid})"
        exit
      end
    end
  end

  def create_pid_file file
    File.open(file, "w") { |f| f.puts Process.pid }

    # Remove pid file during shutdown
    at_exit do
      LOGGER_PARSER.info "DoroParser", "Shutting down." rescue nil
      if File.exist? file
        File.unlink file
      end
    end
  end

  # Sends SIGTERM to process in pidfile. Server should trap this
  # and shutdown cleanly.
  def self.stop
    LOGGER_PARSER.info "DoroParser", "Shutting down.."
    pid_file = PIDFILE_PARSER
    if pid_file and File.exist? pid_file
      pid = Integer(File.read(pid_file))
      Process.kill -15, -pid
      puts "[DoroParser]".yellow +  " Process #{pid} terminated"
      LOGGER_PARSER.info "DoroParser", "Process #{pid} terminated"
    else
      puts "[DoroParser]".yellow +  "Can't find PID file, is Dorothy really running?"
    end
  end

end