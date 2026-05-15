# frozen_string_literal: true

# Test-only stubs for ActionText. The gem doesn't depend on Rails/ActionText,
# but some tests verify rich-text field handling. These mocks allow that without
# adding Rails as a test dependency.

# Mock ActionText::RichText if not already defined
unless defined?(ActionText)
  module ActionText
    class RichText
      attr_accessor :body

      def initialize(body:)
        @body = body
      end

      def to_html
        body
      end

      def present?
        body.present?
      end
    end
  end
end

# Add html_safe to String (Rails method) - check if it already exists
begin
  String.instance_method(:html_safe)
rescue NameError
  # Method doesn't exist, so add it
  String.class_eval do
    def html_safe
      self
    end
  end
end

# Add has_rich_text macro to ActiveRecord::Base
unless ActiveRecord::Base.respond_to?(:has_rich_text)
  ActiveRecord::Base.class_eval do
    def self.has_rich_text(name, encrypted: false)
      self.rich_text_attributes ||= []
      self.rich_text_attributes << name.to_sym

      body_column = "#{name}_body"

      define_method(name) do
        body = read_attribute(body_column)
        body.nil? ? nil : ActionText::RichText.new(body: body)
      end

      define_method("#{name}=") do |value|
        if value.nil?
          write_attribute(body_column, nil)
        else
          write_attribute(body_column, value.body)
        end
      end
    end

    def self.rich_text_attributes
      @rich_text_attributes ||= []
    end

    def self.rich_text_attributes=(attrs)
      @rich_text_attributes = attrs
    end
  end
end
