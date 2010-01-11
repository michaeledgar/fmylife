# Methods for parser-agnostic parsing
module CanParse
  # Helper method that encapsulates a string into an XML document
  def xml_doc(body)
    case FMyLife.parser
    when :nokogiri
      Nokogiri::XML(body)
    when :hpricot
      Hpricot(body)
    when :rexml
      REXML::Document.new(body)
    when :libxml
      LibXML::XML::Parser.string(body).parse
    end
  end
  
  def xpath(element,path)
    case FMyLife.parser
    when :nokogiri
      element.xpath(path)
    when :hpricot
      puts "in hpricot"
      element/path #force the //
    when :rexml
      REXML::XPath.match(element,path)
    when :libxml
      element.find(path)
    end
  end
  
  def xml_content(element)
    case FMyLife.parser
    when :nokogiri
      element.content
    when :hpricot
      element.inner_text
    when :rexml
      element.text
    when :libxml
      element.content
    end
  end
  
  def xml_attribute(element,attribute)
    case FMyLife.parser
    when :nokogiri
      element[attribute]
    when :hpricot
      element.get_attribute(attribute)
    when :rexml
      element.attributes[attribute]
    when :nokogiri
      element.attributes[attribute]
    end
  end
end

# Generic XML Structure
class XMLStruct
  
  include CanParse
  extend CanParse
  
  class << self
    
    attr_accessor :fields
    
    def field(name, type, getter, path="")
      @fields ||= {}
      if type == :attribute
        @fields[name.to_sym] = {:type => type, :getter => getter, :path => path}
      else
        @fields[name.to_sym] = {:type => type, :getter => getter}
      end
      attr_accessor name
      
    end
  end
  
  def post_initialize; end
  
  def initialize(opts = {})
    if opts[:xml]
      parse_xml opts[:xml]
    else
      opts.each do |key, value|
        instance_variable_set("@#{key}".to_sym, value)
      end
    end
    post_initialize
    self
  end
  
  def parse_xml(entry)
    myfields = self.class.fields
    myfields.each do |k,v|
      if v[:getter].is_a?(String) || v[:getter].is_a?(Symbol)
        if v[:type] == :attribute
          instance_variable_set("@#{k}".to_sym, xml_attribute(xpath(entry,v[:path]).first, v[:getter].to_s))
        elsif v[:type] == :node
          node = xpath(entry, v[:getter].to_s).first
          if node
            instance_variable_set "@#{k}".to_sym, xml_content(node)
          end
        end
      elsif v[:getter].is_a?(Proc)
        instance_variable_set "@#{k}".to_sym, v[:getter].call(entry)
      end
    end
  end
end