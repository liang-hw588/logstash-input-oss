# encoding: utf-8

require "logstash/inputs/base"
require "logstash/namespace"

require "stud/interval"
require "json"

require "fileutils"
require "digest/md5"

require 'aliyun/oss'

class LogStash::Inputs::Oss < LogStash::Inputs::Base
  config_name "oss"

  default :codec, "plain"

  config :access_key_id, :validate => :string, :default => nil
  config :access_key_secret, :validate => :string, :default => nil

  config :endpoint, :validate => :string, :default => nil

  config :bucket, :validate => :string, :default => nil
  config :prefix, :validate => :string, :default => ""

  config :interval, :validate => :number, :default => 60 * 60

  config :db_path, :validate => :string, :default => nil

  config :temp_dir, :validate => :string, :default => File.join(Dir.tmpdir, "logstash-inputs-oss")
  
  def register
    @oss_client = Aliyun::OSS::Client.new(
                                          :endpoint => @endpoint,
                                          :access_key_id => @access_key_id,
                                          :access_key_secret => @access_key_secret)
    @oss_bucket = @oss_client.get_bucket(@bucket)

    @sincedb = SinceDB::File.new(sincedb_file(@db_path))

    FileUtils.mkdir_p(@temp_dir) unless Dir.exists?(@temp_dir)
  end

  def run(queue)
    @current_thread = Thread.current

    Stud.interval(@interval) do
      process_new_objects(queue)
    end
  end

  def stop
    Stud.stop!(@current_thread)
  end

  def sincedb_file(pathname)
    pathname ||= File.join(ENV["HOME"], ".logstash-input-oss")
    filename = File.join(pathname, "db-#{@bucket}-" + Digest::MD5.hexdigest("#{@prefix}"))
  end

  def new_objects
    @oss_bucket.list_objects(:prefix=@prefix, :marker=@sincedb.marker)
  end

  def process_new_objects(queue)
    new_objects().each do |obj|
      if stop?
        @logger.info("stop while attempting to read log file")
        break
      end

      process_one_object(queue, obj.key)
    end
  end

  def process_one_object(queue, key)
    filename = local_filename(key)
    @oss_bucket.get_object(key, :file => filename)

    read_file(filename) do |line|
      if stop?
        @logger.info("stop while reading the log file")
        return false
      end

      @logger.info("start processing ", :bucket => @bucket, :key => key, :file => filename)

      @codec.decode(line) do |event|
        decorate(event)
        queue << event
      end

      @sincedb.marker = key

      @logger.info("finish processing ", :bucket => @bucket, :key => key, :file => filename)
    end

    FileUtils.remove_entry_secure(filename, true)

    return true
  end

  def local_filename(key)
    File.join(@temp_dir, Digest::MD5.hexdigest(key))
  end

  def read_file(filename, block)
    File.open(filename, 'rb') do |file|
      file.each(&block)
    end
  end
  
  
  private
  module SinceDB
    class File
      def initialize(filename)
        @filename = filename

        dirname = File.dirname(@filename)
        unless Dir.exists?(dirname)
          Dir.mkdir_p(dirname)
        end

        unless ::File.exists?(@filename)
          ::File.open(@filename, 'w') { |f| f.write("{\"marker\": \"\"}") }
        end

        @config = JSON.parse(::File.read(@filename))
      end

      def marker
        @config["marker"]
      end

      def marker=(marker)
        @config["marker"] = marker
        ::File.open(@filename, "w") do |f|
          f.write(JSON.pretty_generate(@config))
        end
      end
    end
  end
end