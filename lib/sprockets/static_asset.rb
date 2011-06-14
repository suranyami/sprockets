require 'multi_json'
require 'time'

module Sprockets
  class StaticAsset
    attr_reader :environment
    attr_reader :logical_path, :pathname
    attr_reader :content_type, :mtime, :length, :digest

    def self.from_json(environment, hash)
      asset = allocate
      asset.initialize_json(environment, hash)
      asset
    end

    def initialize(environment, logical_path, pathname, digest = nil)
      @environment = environment

      @logical_path = logical_path.to_s
      @pathname     = Pathname.new(pathname)
      @content_type = environment.content_type_of(pathname)

      @mtime  = @environment.stat(@pathname).mtime
      @length = @environment.stat(@pathname).size
      @digest = digest || environment.file_digest(pathname).hexdigest
      @environment_digest = environment.digest.hexdigest
    end

    def initialize_json(environment, hash)
      @environment = environment

      @logical_path = hash['logical_path'].to_s
      @pathname     = Pathname.new(hash['pathname'])
      @content_type = hash['content_type']
      @mtime        = Time.parse(hash['mtime'])
      @length       = hash['length']
      @digest       = hash['digest']
      @environment_digest = hash['environment_digest']
    end

    def dependencies
      []
    end

    def dependencies?
      false
    end

    def to_a
      [self]
    end

    def body
      to_s
    end

    def fresh?
      if environment.digest != @environment_digest
        false
      elsif (stat = @environment.stat(pathname)) && mtime >= stat.mtime
        true
      elsif (d = environment.file_digest(pathname)) && d.hexdigest == digest
        true
      else
        false
      end
    end

    def stale?
      !fresh?
    end

    def each
      yield to_s
    end

    def to_path
      pathname.to_s
    end

    def to_s
      pathname.open('rb') { |f| f.read }
    end

    def eql?(other)
      other.class == self.class &&
        other.pathname == self.pathname &&
        other.mtime == self.mtime &&
        other.digest == self.digest
    end
    alias_method :==, :eql?

    def as_json
      {
        'class'        => 'StaticAsset',
        'logical_path' => logical_path,
        'pathname'     => pathname.to_s,
        'content_type' => content_type,
        'mtime'        => mtime,
        'digest'       => digest,
        'length'       => length,
        'environment_digest' => @environment_digest
      }
    end

    def to_json
      MultiJson.encode(as_json)
    end
  end
end
