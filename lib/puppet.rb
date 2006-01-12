require 'singleton'
require 'puppet/log'
require 'puppet/util'

# see the bottom of the file for further inclusions

#------------------------------------------------------------
# the top-level module
#
# all this really does is dictate how the whole system behaves, through
# preferences for things like debugging
#
# it's also a place to find top-level commands like 'debug'
module Puppet
PUPPETVERSION = '0.10.2'

    def Puppet.version
        return PUPPETVERSION
    end

    class Error < RuntimeError
        attr_accessor :stack, :line, :file
        def initialize(message)
            @message = message

            @stack = caller
        end

        def to_s
            str = nil
            if defined? @file and defined? @line and @file and @line
                str = "%s in file %s at line %s" %
                    [@message.to_s, @file, @line]
            elsif defined? @line and @line
                str = "%s at line %s" %
                    [@message.to_s, @line]
            else
                str = @message.to_s
            end

            #if Puppet[:debug] and @stack
            #    str += @stack.to_s
            #end

            return str
        end
    end

    class DevError < Error; end

    # the hash that determines how our system behaves
    @@config = Hash.new(false)

    # define helper messages for each of the message levels
    Puppet::Log.eachlevel { |level|
        define_method(level,proc { |args|
            if args.is_a?(Array)
                args = args.join(" ")
            end
            Puppet::Log.create(
                :level => level,
                :message => args
            )
        })
        module_function level
    }

    # I keep wanting to use Puppet.error
    # XXX this isn't actually working right now
    alias :error :err

    @defaults = {
        :name           => $0.gsub(/.+#{File::SEPARATOR}/,''),
        :rrddir         => [:puppetvar,      "rrd"],
        :logdir         => [:puppetvar,      "log"],
        :bucketdir      => [:puppetvar,      "bucket"],
        :statedir       => [:puppetvar,      "state"],
        :rundir         => [:puppetvar,      "run"],

        # then the files},
        :manifestdir    => [:puppetconf,     "manifests"],
        :manifest       => [:manifestdir,    "site.pp"],
        :localconfig    => [:puppetconf,     "localconfig.ma"],
        :logfile        => [:logdir,         "puppet.log"],
        :httplogfile    => [:logdir,         "http.log"],
        :masterlog      => [:logdir,         "puppetmaster.log"],
        :masterhttplog  => [:logdir,         "masterhttp.log"],
        :checksumfile   => [:statedir,       "checksums"],
        :ssldir         => [:puppetconf,     "ssl"],

        # and finally the simple answers,
        :server         => "puppet",
        :user           => "puppet",
        :group          => "puppet",
        :rrdgraph       => false,
        :noop           => false,
        :parseonly      => false,
        :puppetport     => 8139,
        :masterport     => 8140,
    }

    # If we're running the standalone puppet process as a non-root user,
    # use basedirs that are in the user's home directory.
    if @defaults[:name] == "puppet" and Process.uid != 0
        @defaults[:puppetconf] = File.expand_path("~/.puppet")
        @defaults[:puppetvar] = File.expand_path("~/.puppet/var")
    else
        # Else, use system-wide directories.
        @defaults[:puppetconf] = "/etc/puppet"
        @defaults[:puppetvar] = "/var/puppet"
    end

    def self.clear
        @@config = Hash.new(false)
    end

	# configuration parameter access and stuff
	def self.[](param)
        if param.is_a?(String)
            param = param.intern
        elsif ! param.is_a?(Symbol)
            raise ArgumentError, "Invalid parameter type %s" % param.class
        end
        case param
        when :debug:
            if Puppet::Log.level == :debug
                return true
            else
                return false
            end
        when :loglevel:
            return Puppet::Log.level
        else
            # allow manual override
            if @@config.include?(param)
                return @@config[param]
            else
                if @defaults.include?(param)
                    default = @defaults[param]
                    if default.is_a?(Proc)
                        return default.call()
                    elsif default.is_a?(Array)
                        return File.join(self[default[0]], default[1])
                    else
                        return default
                    end
                else
                    raise ArgumentError, "Invalid parameter %s" % param
                end
            end
        end
	end

	# configuration parameter access and stuff
	def self.[]=(param,value)
        case param
        when :debug:
            if value
                Puppet::Log.level=(:debug)
            else
                Puppet::Log.level=(:notice)
            end
        when :loglevel:
            Puppet::Log.level=(value)
        when :logdest:
            Puppet::Log.newdestination(value)
        else
            @@config[param] = value
        end
	end

    def self.asuser(user)
        # FIXME this should use our user object, since it already knows how
        # to find users and such
        require 'etc'

        begin
            obj = Etc.getpwnam(user)
        rescue ArgumentError
            raise Puppet::Error, "User %s not found"
        end

        uid = obj.uid

        olduid = nil
        if Process.uid != uid
            olduid = Process.uid
            Process.euid = uid
        end

        retval = yield


        if olduid
            Process.euid = olduid
        end

        return retval
    end

    def self.setdefault(param,value)
        if value.is_a?(Array) 
            if value[0].is_a?(Symbol) 
                unless @defaults.include?(value[0])
                    raise ArgumentError, "Unknown basedir %s for param %s" %
                        [value[0], param]
                end
            else
                raise ArgumentError, "Invalid default %s for param %s" %
                    [value.inspect, param]
            end

            unless value[1].is_a?(String)
                raise ArgumentError, "Invalid default %s for param %s" %
                    [value.inspect, param]
            end

            unless value.length == 2
                raise ArgumentError, "Invalid default %s for param %s" %
                    [value.inspect, param]
            end

            @defaults[param] = value
        else
            @defaults[param] = value
        end
    end

    # XXX this should all be done using puppet objects, not using
    # normal mkdir
    def self.recmkdir(dir,mode = 0755)
        if FileTest.exist?(dir)
            return false
        else
            tmp = dir.sub(/^\//,'')
            path = [File::SEPARATOR]
            tmp.split(File::SEPARATOR).each { |dir|
                path.push dir
                if ! FileTest.exist?(File.join(path))
                    Dir.mkdir(File.join(path), mode)
                elsif FileTest.directory?(File.join(path))
                    next
                else FileTest.exist?(File.join(path))
                    raise "Cannot create %s: basedir %s is a file" %
                        [dir, File.join(path)]
                end
            }
            return true
        end
    end

    # Create a new type
    def self.newtype(name, parent = nil, &block)
        parent ||= Puppet::Type
        Puppet::Util.symbolize(name)
        t = Class.new(parent) do
            @name = name
        end
        t.class_eval(&block)
        @types ||= {}
        @types[name] = t 
    end

    # Retrieve a type by name
    def self.type(name)
        unless defined? @types
            return nil
        end
        return @types[name]
    end
end

require 'puppet/server'
require 'puppet/type'
require 'puppet/storage'

# $Id$
