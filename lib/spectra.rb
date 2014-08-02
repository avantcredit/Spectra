
require 'spectra/version'
require 'extensions'

module Spectra
  
  def self.generate
    Root.new.generate
  end

  ##
  ## DSL Interface
  ##
  
  module DSL
    def prefix(prefix)
      self._prefix = prefix 
    end
  
    def formats(*types) 
      types.each { |type| format(type) }
    end

    def format(type, path = nil, &renamer)
      self.serializers ||= []
      self.serializers.concat(Serializer.from_type(type, path, renamer))
    end
     
    def color(name, attributes)
      self.colors ||= []
      self.colors << Color.new(name, attributes)
    end

    def components(*components)
      components.hash_from(:red, :green, :blue, :alpha)
    end

    def hex(*components)
      components.hash_from(:hex, :alpha)
    end

    def white(*components)
      components.hash_from(:white, :alpha)
    end
     
  end 

  ##
  ## Models
  ##
 
  class Root
    
    attr_accessor :_prefix
    attr_accessor :colors, :serializers

    include DSL

    def generate
      definition = IO.read('colors.rb')

      self.instance_eval definition    
      self.formats(:palette, :objc) unless self.serializers

      self.serializers.each do |serializer|
        serializer.serialize(self)
      end
    end 

  end

  class Color

    attr_accessor :name, :components
    
    def initialize(name, attributes)
      self.name = name
      self.components = self.components_from_attributes(attributes)
    end 

    def method_missing(name)
      self.valid_components.include?(name) ? self.components[name] : super
    end

    def valid_components
      [ :red, :green, :blue, :white, :alpha ]
    end

    ##
    ## Component Generation
    ##

    def components_from_attributes(attributes)
      components = map_attributes(attributes).pick(*self.valid_components)
      hex, white = attributes[:hex], components[:white]

      components[:alpha] ||= 1.0
      components.merge!(componentize_hex(hex)) if hex 
      components.merge!(componentize_white(white)) if white
      
      components.each { |key, value| components[key] = normalize(value) }
    end

    def componentize_hex(value)
      hex = value.is_a?(String) ? value.to_i : value
      return {
        red:   (hex & 0xFF0000) >> 16,
        green: (hex & 0x00FF00) >> 8,
        blue:  (hex & 0x0000FF)
      }    
    end

    def componentize_white(value)
      return { red: value, green: value, blue: value }
    end

    ##
    ## Helpers
    ##

    def normalize(number)
      number = number / 255.0 if number.is_a?(Fixnum)
      raise "component #{number} is not in a legible format" unless number.is_a?(Float)
      number.limit(0.0..1.0) 
    end
   
    def map_attributes(attributes)
      key_map = { r: :red, g: :green, b: :blue, w: :white, a: :alpha }
      return Hash[attributes.map { |key, value| [ key_map[key] || key, value ] }] 
    end

    ##
    ## Debugging
    ##

    def inspect
      return "#{self.name} :: #{self.components}" 
    end

  end

  ##
  ## Serializers
  ##

  class Serializer

    attr_accessor :formatter, :base_path

    def initialize(attributes)
      self.formatter = Formatter.from_attributes(attributes)
      self.base_path = attributes[:path]
    end

    def serialize(spectrum)
      path, text = self.resource_path(spectrum), self.formatter.format(spectrum)
      File.open(path, 'w+') { |file| file.write(text) }
    end

    def resource_path(spectrum)
      base_path = self.base_path || self.formatter.path
      base_path << '/' unless base_path.end_with?('/')
      base_path + self.formatter.filename(spectrum)
    end

    ##
    ## Factory
    ##

    def self.from_type(type, path, renamer)
      attributes = { path: path, formatter_type: type, renamer: renamer }

      case type.intern
        when :palette
          [ Serializer.new(attributes) ]
        when :objc
          [ Serializer.new(attributes.merge(is_header: true)), Serializer.new(attributes) ]
        when :swift
          [ Serializer.new(attributes) ]
        else raise "Specfied an invalid format: #{type}"
      end
    end

  end

  ##
  ## Formatters
  ##

  class Formatter 
   
    attr_accessor :renamer
    attr_accessor :post_prefix_newlines, :intercolor_newlines, :pre_suffix_newlines
    
    def initialize(attributes)
      self.renamer = attributes[:renamer] 
      self.post_prefix_newlines = self.intercolor_newlines = self.pre_suffix_newlines = 1
    end 

    ##
    ## Formatting
    ## 

    def format(spectrum)
      output = self.prefix(spectrum) + "\n" * self.post_prefix_newlines
      spectrum.colors.each_with_index { |color, index| output << format_indexed_color(color, index, spectrum) }
      output + "\n" * self.pre_suffix_newlines + self.suffix(spectrum)
    end

    def path
      './'
    end
    
    ##
    ## Helpers
    ##

    def format_indexed_color(color, index, spectrum)
      name     = self.format_name(color, spectrum)
      newlines = index < spectrum.colors.length - 1 ? self.intercolor_newlines : 0
      self.format_color(color, name) + "\n" * newlines
    end

    def format_name(color, spectrum)
      self.renamer.call(color.name, spectrum._prefix)
    end

    def prefix(spectrum)
      ""
    end

    def suffix(spectrum)
      ""
    end

    ##
    ## Factory
    ##
     
    def self.from_attributes(attributes)
      case attributes[:formatter_type].intern
        when :palette
          PaletteFormatter.new(attributes)
        when :objc    
          ObjcCategoryFormatter.new(attributes)
        when :swift   
          SwiftExtensionFormatter.new(attributes)
      end
    end

  end

  class PaletteFormatter < Formatter
    
    ##
    ## Formatting Hooks
    ##

    def prefix(spectrum)
      "11"
    end

    def format_color(color, name)
      components = [ color.red, color.green, color.blue, color.alpha ]
      components.inject('0') { |memo, value| memo << ' ' << '%.3f' % (value || 0.0) } + " #{name}"
    end

    def renamer
      @renamer ||= lambda { |name, prefix| name.camelize(true) }
    end

    ##
    ## Pathing Hooks
    ##
    
    def path
      "#{Dir.home}/Library/Colors/"
    end

    def filename(spectrum)
      "#{spectrum._prefix}-palette.clr"
    end

    ##
    ## Helpers
    ##

    def format_value(value)
      '%.3f' % (value || 0.0)
    end

  end

  class ObjcCategoryFormatter < Formatter 
    
    attr_accessor :is_header

    def initialize(attributes)
      super(attributes)
      self.is_header = attributes[:is_header] 

      self.post_prefix_newlines = self.pre_suffix_newlines = 2
      self.intercolor_newlines  = is_header ? 1 : 2
    end
    
    ##
    ## Subclassing Hooks
    ##

    def prefix(spectrum)
      prefix =  "//\n"
      prefix << "// #{self.filename(spectrum)}\n"
      prefix << "// This file is generated by Spectrum, so don't expect to make any persistent changes.\n"
      prefix << "//\n\n"
      prefix +  "@#{self.is_header ? 'interface' : 'implementation'} UIColor (#{spectrum._prefix.upcase}Color)"
    end

    def format_color(color, name)
      signature = "+ (UIColor *)#{name}"
      if self.is_header
        "#{signature};"
      else
        "#{signature}\n{\n    return #{self.format_implementation(color)};\n}"
      end
    end

    def suffix(attributes)
      "@end"
    end

    def renamer
      @renamer ||= lambda { |name, prefix| "#{prefix}_#{name.camelize(false)}Color" }
    end

    ##
    ## Pathing Hooks
    ##

    def filename(spectrum)
      "UIColor+#{spectrum._prefix.upcase}Color.#{self.is_header ? 'h' : 'm'}"
    end
    
    ##
    ## Helpers
    ##

    def format_implementation(color)
      if color.white
        "[UIColor colorWithWhite:#{format_value(color.white)} alpha:#{format_value(color.alpha)}]"  
      else
        "[UIColor colorWithRed:#{format_value(color.red)} green:#{format_value(color.green)} blue:#{format_value(color.blue)} alpha:#{format_value(color.alpha)}]"
      end      
    end

    def format_value(value)
      '%.2f' % (value || 0.0) + 'f' 
    end
   
  end

  class SwiftExtensionFormatter < Formatter

  end 

end
