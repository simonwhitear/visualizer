require 'geoip'
require 'sinatra'
require 'redis'
require 'json'

class RepsheetVisualizer < Sinatra::Base
  # Grab the mount point before every request
  before do
    @mount = mount
  end

  helpers do
    def action(ip, blacklist=nil)
      puts ip.inspect
      puts blacklist.inspect
      blacklist = redis_connection.get("#{ip}:repsheet:blacklist") if blacklist.nil?
      if blacklist.nil? || blacklist == "false"
        "blacklist"
      else
        "allow"
      end
    end
  end

  # Settings methods
  def redis_connection
    host = defined?(settings.redis_host) ? settings.redis_host : "localhost"
    port = defined?(settings.redis_port) ? settings.redis_port : 6379
    Redis.new(:host => host, :port => port)
  end

  def geoip_database
    geoip_database = defined?(settings.geoip_database) ? settings.geoip_database : nil
    raise "Missing GeoIP database settings" if geoip_database.nil?
    raise "Could not locate GeoIP database" unless File.exist?(geoip_database)
    GeoIP.new(settings.geoip_database)
  end

  def mount
    defined?(settings.mount) ? (settings.mount + "/") : "/"
  end

  # TODO: These methods should get moved out to another place
  def summary(connection)
    suspects = {}
    blacklisted = {}

    connection.keys("*:requests").map {|d| d.split(":").first}.reject {|ip| ip.empty?}.each do |actor|
      detected = connection.smembers("#{actor}:detected").join(", ")
      blacklist = connection.get("#{actor}:repsheet:blacklist")

      if !detected.empty? && blacklist != "true"
        suspects[actor] = Hash.new 0
        suspects[actor][:detected] = detected
        connection.smembers("#{actor}:detected").each do |rule|
          suspects[actor][:total] += connection.get("#{actor}:#{rule}:count").to_i
        end
      end

      if blacklist == "true"
        blacklisted[actor] = Hash.new 0
        blacklisted[actor][:detected] = detected
        connection.smembers("#{actor}:detected").each do |rule|
          blacklisted[actor][:total] += connection.get("#{actor}:#{rule}:count").to_i
        end
      end
    end

    [suspects.sort_by{|k,v| -v[:total]}.take(10), blacklisted]
  end

  def breakdown(connection)
    data = {}
    offenders = connection.keys("*:repsheet").map {|o| o.split(":").first}
    offenders.each do |offender|
      data[offender] = {"totals" => {}}
      connection.smembers("#{offender}:detected").each do |rule|
        data[offender]["totals"][rule] = connection.get "#{offender}:#{rule}:count"
      end
    end
    aggregate = Hash.new 0
    data.each {|ip,data| data["totals"].each {|rule,count| aggregate[rule] += count.to_i}}
    [data, aggregate]
  end

  def activity(connection)
    connection.lrange("#{@ip}:requests", 0, -1)
  end

  def worldview(connection, database)
    data = {}
    offenders = connection.keys("*:repsheet*").map {|o| o.split(":").first}
    offenders.each do |address|
      details = database.country(address)
      next if details.nil?
      data[address] = [details.latitude, details.longitude]
    end
    data
  end

  # This is the actual application
  get '/' do
    @suspects, @blacklisted = summary(redis_connection)
    erb :actors
  end

  get '/breakdown' do
    @data, @aggregate = breakdown(redis_connection)
    erb :breakdown
  end

  get '/worldview' do
    @data = worldview(redis_connection, geoip_database)
    erb :worldview
  end

  get '/activity/:ip' do
    @ip = params[:ip]
    @data = activity(redis_connection)
    erb :activity
  end

  post '/action' do
    connection = redis_connection
    if params["action"] == "allow"
      connection.set("#{params[:ip]}:repsheet:blacklist", "false")
    else
      connection.set("#{params[:ip]}:repsheet:blacklist", "true")
    end
    redirect back
  end
end
