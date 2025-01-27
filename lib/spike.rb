require 'forwardable'
require 'json'
require 'pathname'
require 'active_support/inflector'

module Spike
  class Resource
    attr_reader :path, :segments
    def initialize(path)
      @path = path.to_s
      @segments = @path.split("/").reject(&:empty?)
    end

    def name
      s = objects.first
      if subresource?
        prefix, resource = objects
        s = [prefix.singularize, resource].join("_")
      end
      singular?? s.singularize : s
    end

    def singular?
      segments.last =~ /:.*id$/
    end

    def subresource?
      objects.count > 1
    end

    def objects
      return @objects if defined?(@objects)

      @objects = segments.reject {|segment| segment.start_with?(":")}
      if @objects.count > 1
        @objects = @objects.reject {|resource| resource == "repos"}
      end
      @objects
    end
  end

  class Routes
    attr_reader :definition
    def initialize(json)
      @definition = JSON.parse(json, object_class: OpenStruct)
      normalize!
    end

    private

    def normalize!
      @definition["original_path"] = definition.path
      @definition["path"]          = normalized_path
      @definition["params"]        = normalized_params

      @definition["documentation_url"] = @definition["documentationUrl"]
      @definition["verb"]              = @definition["method"]
    end

    def normalized_path
      path = definition.path.to_s
      if definition.path.to_s.include?(":id")
        idx = original_path_segments.index(":id")
        resource = original_path_segments[idx-1].singularize
        path = path.gsub(":id", ":#{resource}_id")
      end
      path
    end

    def normalized_params
      params = (@definition.params || []).reject do |param|
        param.name == "owner"
      end

      params.each do |param|
        if param.name == "id"
          idx = original_path_segments.index(":id")
          resource = original_path_segments[idx-1].singularize
          param["name"] = "#{resource}_id"
        end
        if param.name.end_with?("_id") && param.type == "string"
          param["type"] = "integer"
        end
        if param.name == "repo"
          param["description"] = "A GitHub repository"
        end
        if param.description == "" && param.name.end_with?("_id")
          param["description"] = "The ID of the #{param.name.gsub("_id", "").gsub("_", " ")}"
        end
        param.description = param.description.to_s.gsub(" Please see more in the alert below.", "")
        if param.type.to_s.end_with?("[]")
          param["type"] = "Array<#{param.type.gsub("[]", "")}>"
        end
      end

      resource = Spike::Resource.new(definition.path)
      if resource.subresource?
        id_param = params.find {|param| param.name =~ /.*id/}&.name
        if id_param
          idx = path_segments.index(":#{id_param}")
          resource = path_segments[idx-1].singularize
          params = params.reject {|param|
            ["repo", id_param].include?(param.name)
          }
          url_param = {
            name: "#{resource}_url",
            required: true,
            type: "string",
            description: "A URL for a #{resource} resource.",
          }
          params = params.unshift OpenStruct.new(url_param)
        end
      end

      params
    end

    def path_segments
      definition.path.to_s.split("/").reject(&:empty?)
    end

    def original_path_segments
      definition.original_path.to_s.split("/")
    end
  end

  class Endpoint
    class PositionalParameterizer
      def parameterize(args)
        "#{args.join(", ")}, options = {}"
      end
    end

    class KwargsParameterizer
      def parameterize(args)
        "#{args.map {|arg| arg + ":"}.join(", ")}, **options"
      end
    end

    extend Forwardable

    VERB_PRIORITY = %w(GET POST)

    delegate [:documentation_url] => :definition

    attr_reader :definition, :resource, :directory, :parameterizer
    def initialize(definition, directory: "", parameterizer: Spike::Endpoint::PositionalParameterizer)
      @definition    = definition
      @resource      = Spike::Resource.new(definition.path)
      @directory     = directory
      @parameterizer = parameterizer.new
    end

    def to_s
      [
        tomdoc,
        method_definition,
        alias_definition,
      ].compact.join("\n")
    end

    def tomdoc
      <<-TOMDOC.chomp
      # #{definition.name}
      #
      # #{parameter_documentation.join("\n      # ")}
      # @return #{return_type_description} #{return_value_description}
      # @see #{documentation_url}
      TOMDOC
    end

    def method_definition
      <<-DEF.chomp
      def #{method_name}(#{parameters})
        #{resource.subresource?? subresource_method_implementation : method_implementation}
      end
      DEF
    end

    def alias_definition
      return unless alternate_name
      "      alias :#{alternate_name} :#{method_name}"
    end

    def method_implementation
      [
        *option_overrides,
        api_call,
      ].reject(&:empty?).join("\n        ")
    end

    def subresource_method_implementation
      url_param = definition.params.find {|param| param.name.end_with?("_url")}
      the_resource = resource.objects.first.singularize
      s = "#{the_resource} = get(#{url_param.name}, accept: options[:accept])"
      unless option_overrides.empty?
        s << "\n        "
        s << option_overrides.join("\n        ")
      end
      s << "\n        #{definition.verb.downcase}(#{the_resource}.rels[:#{resource.objects.last}].href, options)"
    end

    def option_overrides
      definition.params.select(&:required).reject do |param|
        definition.path.include?(":#{param.name}") || param.name.end_with?("_url")
      end.map do |param|
        normalization = ""
        if !!param.enum
          normalization = ".to_s.downcase"
        end
        "options[:#{param.name}] = #{param.name}#{normalization}"
      end
    end

    def api_call
      "#{definition.verb.downcase}(\"#{api_path}\", options)"
    end

    def api_path
      path = definition.path
      path = path.gsub("/repos/:owner/:repo", "\#{Repository.path repo}")
      path = definition.params.select(&:required).reduce(path) do |path, param|
        path.gsub(":#{param.name}", "\#{#{param.name}}")
      end
    end

    def return_type_description
      if definition.verb == "GET" && !resource.singular?
        "[Array<Sawyer::Resource>]"
      else
        "<Sawyer::Resource>"
      end
    end

    def parameter_type(parameter)
      {
        "repo" => "[Integer, String, Repository, Hash]",
      }[parameter.name] || "[#{parameter.type.capitalize}]"
    end

    def parameter_description(parameter)
      return parameter.description unless parameter.description.empty?
      return "A GitHub repository" if parameter.name == "repo"

      "The ID of the #{parameter.name.gsub("_id", "").gsub("_", " ")}" if parameter.name.end_with?("_id")
    end

    def parameter_documentation
      definition.params.select(&:required).map {|param|
        "@param #{param.name} #{parameter_type(param)} #{parameter_description(param)}"
      } + definition.params.reject(&:required).reject {|param| ["per_page", "page"].include?(param.name)}.map {|param|
        "@param options [#{param.type.capitalize}] :#{param.name} #{param.description}"
      }
    end

    def return_value_description
      case verb
      when "GET"
        if resource.singular?
          "A single #{resource.name.gsub("_", " ")}"
        else
          "A list of #{resource.name.gsub("_", " ")}"
        end
      when "POST"
        "The new #{resource.name.singularize.gsub("_", " ")}"
      else
      end
    end

    def verb
      definition["method"]
    end

    def parameters
      parameterizer.parameterize(arguments)
    end

    def arguments
      definition.params.select(&:required).map(&:name)
    end

    def resource
      return @resource if defined?(@resource)

      final_segment = path_segments.reject {|segment| segment.start_with?(":")}.last
      if final_segment == directory
        @resource = final_segment
      else
        @resource = [directory.singularize, final_segment].join("_")
      end
    end

    def path_segments
      @path_segments ||= definition.path.to_s.split("/").reject(&:empty?)
    end

    def method_name
      case verb
      when "GET"
        resource.name
      when "POST"
        "create_#{resource.name.singularize}"
      else
      end
    end

    def alternate_name
      return unless definition.verb == "GET"
      return if resource.singular?
      "list_#{resource.name}"
    end

    def parts
      @parts ||= path_segments[path_segments.index(directory)..-1].reject {|segment| segment.start_with?(":")}
    end

    def priority
      [parts.count, VERB_PRIORITY.index(verb), resource.singular?? 0 : 1]
    end
  end

  class API
    def self.at(path, parameterizer: Spike::Endpoint::PositionalParameterizer)
      files = Dir.entries(path) - %w(. ..)
      endpoints = files.map do |file|
        definition = Spike::Routes.new(File.read(File.join(path, file))).definition
        Spike::Endpoint.new(definition, directory: Pathname.new(path).basename.to_s, parameterizer: parameterizer)
      end
      new(path, endpoints: endpoints)
    end

    attr_reader :path, :endpoints
    def initialize(path, endpoints: [])
      @path      = path
      @endpoints = endpoints
    end

    def namespace
      Pathname.new(path).basename.to_s.capitalize
    end

    def documentation_url
      endpoints.first&.documentation_url.to_s.gsub(/#.*/, "")
    end

    def to_s
      <<-FILE
module Octokit
  class Client
    # Methods for the #{namespace} API
    #
    # @see #{documentation_url}
    module #{namespace}
#{endpoints.sort_by(&:priority).join("\n\n")}
    end
  end
end
      FILE
    end
  end
end
