require 'liquid'
require 'liquidizer/support'
require 'liquidizer/file_system'


module Liquidizer
  module ControllerExtensions
    def self.included(base)
      base.class_eval do
        extend ClassMethods
        alias_method :render_without_liquid, :render
        alias_method :render, :render_with_liquid

        cattr_accessor :liquidizer_options
        self.liquidizer_options ||= {}

        before_action :set_liquid_file_system
      end
    end

    def render_with_liquid(options = nil, &block)
      # use normal render if "liquify" has not been called in the controller
      # or if there are no liquid templates available
      if !self.class.liquify_enabled? || current_liquid_templates.empty?
        return render_without_liquid(options, &block)
      end

      if view_template = liquid_template_for_view(options)
        options ||= {}
        assigns = assigns_for_liquify
        content = view_template.render!(assigns)

        if layout_template = liquid_template_for_layout(options)
          content = layout_template.render!(assigns.merge('content_for_layout' => content))
          options[:layout] = false
        end

        render_without_liquid(options.merge(:html => content.html_safe))
      else
        if layout_template = liquid_template_for_layout(options)
          assigns = assigns_for_liquify
          options ||= {}
          content = render_to_string(options.merge(:layout => false))
          content = layout_template.render!(assigns.merge('content_for_layout' => content))

          render_without_liquid(options.merge(:html => content.html_safe, :layout => false))
        else
          render_without_liquid(options, &block)
        end
      end
    end

    def template_exists?(name, prefixes = [], partial = false, keys = [], **options)
      name_with_prefix = [prefixes.first, name].compact.join("/")
      super || find_liquid_template(name_with_prefix).present?
    end

    private

    def liquid_template_for_view(options)
      name = options && options[:template]

      unless name
        action = extract_action_for_render(options)

        if action && liquify?(action)
          name = liquid_template_name_for_action(action)
        end
      end

      name && find_and_parse_liquid_template(name)
    end

    def liquify?(action)
      options = self.class.liquidizer_options

      return false unless options[:actions]
      return false if options[:only] && !Array.wrap(options[:only]).include?(action.to_sym)
      return false if options[:except] && Array.wrap(options[:except]).include?(action.to_sym)

      true
    end

    def liquid_template_for_layout(options)
      options ||= {}

      if liquify_layout?(options)
        name = liquid_template_name_for_layout(options)
        name && find_and_parse_liquid_template(name)
      else
        nil
      end
    end

    def liquify_layout?(options)
      if self.class.liquidizer_options[:layout]
        case options[:layout]
        when nil   then liquifiable_options?(options)
        when false then false
        else
          true
        end
      else
        false
      end
    end

    def extract_action_for_render(options)
      if options.nil?
        action_name
      elsif options[:action]
        options[:action]
      elsif liquifiable_options?(options)
        action_name
      else
        nil
      end
    end

    UNLIQUIFIABLE_OPTIONS = [:partial, :file, :plain, :xml, :json, :js, :inline, :nothing]

    def liquifiable_options?(options)
      (options.keys.map(&:to_sym) & UNLIQUIFIABLE_OPTIONS).empty?
    end

    def find_and_parse_liquid_template(name)
      if template_record = find_liquid_template(name)
        template = Liquid::Template.parse(template_record.content)
        prepare_liquid_template(template)

        template
      else
        nil
      end
    end

    def liquid_template_name_for_action(action)
      "#{controller_path}/#{action}"
    end

    def liquid_template_name_for_layout(options)
      options[:layout] || case layout = self.class._layout
                          when Symbol then __send__(layout)
                          when Proc   then layout.call(self)
                          else layout
                          end
    end

    def find_liquid_template(name)
      current_liquid_templates.find_by_name(name)
    end

    # This can be overriden to do some nasty things to the template before it's rendered.
    # For example, +assigns+ and +registers+ can be set here. The +template+ is an
    # instance of Liquid::Template.
    def prepare_liquid_template(template)
    end

    def assigns_for_liquify
      variable_names = instance_variable_names
      variable_names -= self.class::PROTECTED_IVARS.to_a

      assigns = variable_names.inject({}) do |memo, name|
        assign_name = name[/^@(.*)$/, 1]           # strip @
        next memo if assign_name.starts_with?('_') # skip "private" ivars

        value = dropify(instance_variable_get(name))

        memo[assign_name] = value if value
        memo
      end

      if params[:page].present?
        assigns.merge!("current_page" => params[:page])
      end

      assigns
    end

    # Wrap the value in a drop, if it exists. Drop class is infered from the value class:
    #
    #   Foo::Bar -> Foo::BarDrop
    def dropify(value)
      if value.respond_to?(:map) && (
        mapped_value = value.map { |element|
          dropify(element)
        }).present?

        mapped_value
      elsif value.respond_to?(:to_liquid)
        value
      else
        drop_class = infer_drop_class(value)
        drop_class && drop_class.new(value)
      end
    end

    def infer_drop_class(value)
      name = value.class.name + 'Drop'
      name = Liquidizer.drop_module.to_s + '::' + name if Liquidizer.drop_module

      Support.constant_defined?(name) ? name.constantize : nil
    end

    def set_liquid_file_system
      Liquid::Template.file_system = FileSystem.new { current_liquid_templates }
    end

    module ClassMethods
      # Enables liquid rendering.
      #
      # == Examples
      #
      #     # liquify all actions
      #     liquify
      #
      #     # liquify only show and index
      #     liquify :only => [:show, :index]
      #
      #     # liquify all except show and index
      #     liquify :except => [:show, :index]
      #
      #     # liquify all, but do not liquify layout
      #     liquify :layout => false
      #
      def liquify(options = {})
        self.liquidizer_options = options.reverse_merge(:actions => true, :layout => true)
      end

      def liquify_enabled?
        self.liquidizer_options != {}
      end
    end
  end
end

if defined?(ActionController::Base)
  ActionController::Base.send(:include, Liquidizer::ControllerExtensions)
end
