require 'rubygems'
require 'dnssd'
require 'set'
require 'gitjour/version'

Thread.abort_on_exception = true

module Gitjour
  class GitService < Struct.new(:name, :host, :port, :repository, :path, :description)
    def url
      "git://#{host.gsub(/\.$/,"")}#{port == 9418 ? "" : ":#{port}"}/#{path}"
    end
  end

  class Application

    class << self
      def run(*args)
        case args.shift
          when "list"
            list
          when "serve"
            serve(*args)
          when "remote"
            remote(*args)
          when "search"
            search(*args)
          else
            help
        end
      end

      private
      def service_list_display(service_list)
        lines = []
				service_list.inject({}) do |service_by_repository, service|
				  service_by_repository[service.repository] ||= []
				  service_by_repository[service.repository] << service
				  service_by_repository
        end.sort_by do |repository, _|
          repository
        end.each do |(repository, services)|
          lines << "=== #{repository} #{services.length > 1 ? "(#{services.length} copies)" : ""}"
          services.sort_by {|s| s.host}.each do |service|
            lines << "\t#{service.name} #{service.url}"
          end
        end
        lines
      end
      
			def list
			  puts service_list_display(service_list)
			end

      def serve(path=Dir.pwd, *rest)
        path = File.expand_path(path)
        name = rest.shift
        port = rest.shift || 9418

        if File.exists?("#{path}/.git")
          @serving_multiple = false
          announce_repo(path, name, port.to_i)
        else
          Dir["#{path}/*"].each do |dir|
            @serving_multiple = true
            if File.directory?(dir)
              announce_repo(dir, name, 9418)
            end
          end
        end

        `git-daemon --verbose --export-all --port=#{port} --base-path=#{path} --base-path-relaxed`
      end
      
      def search(term)
        puts service_list_display(service_list.select do |s|
          s.search_content.any? {|sc| sc =~ /#{term}/i }
        end).map {|s| $stdout.isatty ? s.gsub(/(#{term})/i, "\033[0;32m\\0\033[0m") : s }
      end

      def help
        puts "Gitjour #{Gitjour::VERSION::STRING}"
        puts "Serve up and use git repositories via Bonjour/DNSSD."
        puts "\nUsage: gitjour <command> [args]"
        puts
        puts "  list"
        puts "      Lists available repositories."
        puts
        puts "  serve <path_to_project> [<name_of_project>] [<port>] or"
        puts "        <path_to_projects>"
        puts "      Serve up the current directory or projects via gitjour."
        puts
        puts "      The name of your project is automatically prefixed with"
        puts "      `git config --get gitjour.prefix` or your username (preference"
        puts "      in that order). If you don't want a prefix, put a ^ on the front"
        puts "      of the name_of_project (the ^ is removed before announcing)."
        puts
        puts "  search <string>"
        puts "      Searches for your string in the name, host, repository, description,"
        puts "      and highlights it in sexy awesomeness (okay, we just colour it in a "
        puts "      little)."
        puts ""
      end

      def exit_with!(message)
        STDERR.puts message
        exit!
      end

      class Done < RuntimeError; end

      def discover(timeout=5)
        waiting_thread = Thread.current

        dns = DNSSD.browse "_git._tcp" do |reply|
          DNSSD.resolve reply.name, reply.type, reply.domain do |resolve_reply|
            service = GitService.new(reply.name,
                                     resolve_reply.target,
                                     resolve_reply.port,
                                     resolve_reply.text_record['repository'].to_s,
                                     resolve_reply.text_record['path'].to_s,
                                     resolve_reply.text_record['description'].to_s)
            begin
              yield service
            rescue Done
              waiting_thread.run
            end
          end
        end

        puts "Gathering for up to #{timeout} seconds..."
        sleep timeout
        dns.stop
      end

      def locate_repo(name)
        found = nil

        discover do |obj|
          if obj.name == name
            found = obj
            raise Done
          end
        end

        return found
      end

      def service_list
        return @list if @list
        @list = Set.new
        discover { |obj| @list << obj }
        return @list
      end

      def announce_repo(path, name, port)
        return unless File.exists?("#{path}/.git")
        
        # If the name's been given and it starts with ^, then don't apply the prefix
        if name && name[0] == ?^
          name[1..-1]
        else
          name = name || File.basename(path)
          prefix = `git config --get gitjour.prefix`.chomp
          prefix = ENV["USER"] if prefix.empty?
          name = [prefix, name].compact.join("-")
        end

        tr = DNSSD::TextRecord.new
        tr['description'] = File.read("#{path}/.git/description") rescue "a git project"
        tr['repository']  = File.basename(path)
        tr['path']        = @serving_multiple ? File.basename(path) : ""

        DNSSD.register(name, "_git._tcp", 'local', port, tr.encode) do |rr|
          puts "Registered #{name} on port #{port}. Starting service."
        end
      end

      private 
      def display_services(services)
        services.each do |service|
          # puts "=== #{service.name} on #{service.host}:#{service.port} ==="
          puts "  gitjour clone #{service.name} # #{service.host}:#{service.port}"
          # if service.description != '' && service.description !~ /^Unnamed repository/
          #   puts "  #{service.description}"
          # end
          # puts
        end
      end

    end
  end
end



