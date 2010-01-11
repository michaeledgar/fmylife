require 'net/http'
require 'uri'
require 'digest'
require 'time'
require File.join File.dirname(__FILE__), 'fmylife', 'xmlstruct.rb'
# = FMyLife
#
# This gem allows the user to access the fmylife.com API, which includes
# reading stories, reading comments, moderating stories that are submitted,
# submitting stories, submitting comments, and searching for stories.
#
# In addition, this gem lets you swap in and out which XML parser you use.
# Since not everyone can take advantage of compiled xml parsers,
# the typically built-in REXML library is available.
#
# The following code will connect with your API key, authenticate as a user,
# grab a page of the latest stories and then download all the comments for the
# very latest story. Then, it will print the names of each comment's author.
#
#    acc = FMyLife::Account.new("yourapikey")
#    acc.authenticate(username,password)
#    latest = acc.latest.first # get the latest story
#    acc.story(latest) # pull comments
#    acc.comments.each do |comm|
#        puts comm.author
#    end
#
# More interestingly, we should be able to submit stories!
# 
#    story = FMyLife::Story.new(:text => "my life sucks. FML", 
#                               :author => "Anonymous", 
#                               :category => :love)
#
# Change parsers as such (you _*MUST*_ pick one before you start accessing the API!)
#
#    FMyLife.parser = :nokogiri
#    FMyLife.parser = :hpricot
#    FMyLife.parser = :rexml
#    FMyLife.parser = :libxml
#
# See the individual docs for more examples.
#
module FMyLife
  VERSION = '0.5.1'
  
  API_ROOT = 'api.betacie.com'
  SANDBOX_ROOT = 'sandbox.betacie.com'
  
  # Categories you are allowed to search and submit with
  AVAILABLE_CATEGORIES = [ :love , :money , :kids , :work , :health , :sex , :miscellaneous ]
  
  class AuthenticationError < StandardError; end
  class RetrievalError < StandardError; end
  class VotingError < StandardError; end
  class InvalidCategoryError < ArgumentError; end
  class VotingTypeError < ArgumentError; end
  class StoryTooLongError < ArgumentError; end
  class UnsupportedParserError < ArgumentError; end
  
  AVAILABLE_PARSERS = [:nokogiri, :hpricot, :rexml, :libxml]
  def self.parser=(val)
    raise UnsupportedParserError.new("An unsupported parser was provided: #{val}") unless AVAILABLE_PARSERS.include? val
    @@parser = val
    case @@parser
    when :nokogiri
      require 'nokogiri'
    when :hpricot
      require 'hpricot'
    when :rexml
      require 'rexml/document'
    when :libxml
      require 'libxml'
    end
  end
  def self.parser
    @@parser
  end
  self.parser = :rexml
  
  # = Account
  # An account/connection to FMyLife.com. This class provides access to all of the
  # features of the FML api.
  #
  class Account
    include CanParse
    
    attr_accessor :auth_token
    attr_accessor :api_key
    attr_accessor :sandbox_mode
    
    # Creates an FMyLife with the given developer key. The language can also be 'fr'
    # for French. Sandbox mode defaults to being off.
    def initialize(key = 'readonly', language='en')
      @api_key, @language = key, language
      @sandbox_mode = false
    end
    
    # Logs the connection in with the provided username and password
    def authenticate(username, password)
      path = "/account/login/#{username}/#{Digest::MD5.hexdigest(password)}"
      doc = http_post(path, '')
      
      case code(doc)
      when 0
        raise FMyLife::AuthenticationError.new("Error logging into FMyLife: #{error(doc)}")
      when 1
        @auth_token = xml_content xpath(doc,'//token').first
      end
      self
    end
    
    # Logs the user out of fmylife.com.
    def logout
      raise FMyLife::AuthenticationError.new("You aren't logged in.") if @auth_token.nil?
      path = "/account/logout/#{@auth_token}"
      doc = http_get(path)
      case code(doc)
      when 0
        raise FMyLife::AuthenticationError.new("Error logging out: #{error(doc)}")
      when 1
        @auth_token = nil
      end
    end
    
    # Returns the most recent stories, paginated (starting at 0). Maximum return of 15 stories.
    def latest(page=0)
      path = "/view/last/#{page}"
      retrieve_stories(path)
    end
    
    # Returns a page of the top stories. interval can be "day", "week", or "month", to change
    # how far back to look. Paginated to 15 entries, and +page+ starts at 0.
    def top(interval = nil, page=0)
      param = case interval
              when nil
                "top"
              when :day
                "top_day"
              when :week
                "top_week"
              when :month
                "top_month"
              else
                raise ArgumentError.new("Invalid top-fml interval: #{interval}")
              end
      path = "/view/#{param}/#{page}"
      retrieve_stories(path)
    end
    
    # Returns a page of the "flop" (lowest rated) stories. interval can be "day", "week", or "month",
    # to change how far back to look. Paginated to 15 entries, and +page+ starts at 0.
    def flop(interval = nil, page=0)
      param = case interval.to_sym
              when nil
                "flop"
              when :day
                "flop_day"
              when :week
                "flop_week"
              when :month
                "flop_month"
              else
                raise ArgumentError.new("Invalid flop-fml interval: #{interval}")
              end
      path = "/view/#{param}/#{page}"
      retrieve_stories(path)
    end
    
    # Returns a page of stories with the provided category. You may abbreviate "miscellaneous" as "misc".
    def category(category, page=0)
      category = :miscellaneous if category.to_s =~ /misc/ # poor spellers unite!
      unless FMyLife::AVAILABLE_CATEGORIES.include?(category.to_sym)
        raise InvalidCategoryError.new("You provided an invalid category: #{category}")  
      end
      path = "/view/#{category}/#{page}"
      retrieve_stories(path)
    end
    
    # Gets a random FML story, with or without comments.
    def random(get_comments = true)
      path = "/view/random"
      retrieve_story(path,get_comments)
    end
    
    # Gets a specific +story+, with or without comments. The +_story_+ parameter may be either a
    # FMyLife::Story object, or an ID number.
    def story(_story, get_comments = true)
      number = (_story.is_a? FMyLife::Story) ? _story.id : _story
      path = "/view/#{number}"
      path = path + "/nocomment" unless get_comments
      retrieve_story(path,get_comments)
    end
    
    # Gets the stories that the currently logged-in user has not seen.
    def new
      path = "/view/new"
      retrieve_stories(path,true)
    end
    
    # Gets the currently logged-in user's favorite stories.
    def favorites
      path = "/view/favorites"
      retrieve_stories(path,true)
    end
    
    def search(term)
      path = "/view/search/"
      retrieve_stories(path,false,{:search => term})
    end
    
    # Helper method for retrieving a single story with comments. Internal use only.
    def retrieve_story(path, get_comments = true)
      doc = http_get(path)
      
      case code(doc)
      when 0
        raise FMyLife::RetrievalError.new("Error retrieving story ##{number}: #{error(doc)}")
      when 1
        story = FMyLife::Story.new(:xml => xpath(doc,'//items/item').first)
        if get_comments
          comments = []
          xpath(doc,'//comments/comment').each do |entry|
            comments << FMyLife::Comment.new(:xml => entry)
          end
          story.comments = comments
        end
        story
      end
    end
    
    # Submits a Story to fmylife.com. You must be logged in (with +authenticate+). The +story+ parameter
    # can be either an FMyLife::Story, or a hash with the following values:
    # 
    # [:author] The name of the story's author
    # [:text] The text of the story. Maximum 300 characters.
    # [:cat] The category to use. Must be one of AVAILABLE_CATEGORIES.
    #
    def submit(story)
      raise FMyLife::AuthenticationError.new("You aren't logged in.") if @auth_token.nil?
      params = (story.is_a? FMyLife::Story) ? {:author => story.author, :text => story.text, :cat => story.category} : story
      params[:cat] = params.delete :category if params[:category]
      params[:cat] = :miscellaneous if params[:cat].to_s =~ /misc/
      raise FMyLife::StoryTooLongError.new("Stories can be no longer than 300 characters.") if params[:text].size > 300
      params[:token] = @auth_token
      path = "/submit"
      doc = http_get(path, params)
      case code(doc)
      when 0
        raise VotingError.new("Error while submitting story with text \"#{params[:text]}\": #{error(doc)}")
      when 1
        true
      end
    end
    
    # Votes for a story. +type+ must be :agree or :deserved . Story can be either a FMyLife::Story or an ID number.
    def vote(story, type)
      raise VotingTypeError.new("Your vote must be either 'agree' or 'deserved'.") unless [:agree, :deserved].include? type.to_sym
      id = (story.is_a? FMyLife::Story) ? story.id : story
      path = "/vote/#{id}/#{type}"
      doc = http_get(path)
      case code(doc)
      when 0
        raise VotingError.new("Error while voting on story ##{story.id}: #{error(doc)}")
      when 1
        true
      end
    end
    
    # Submits a Comment to fmylife.com. You must be logged in (with +authenticate+). The +story+ parameter
    # can be either an FMyLife::Story, or an ID number. +arg+ can be an FMyLife::Comment or a hash with 
    # the following values:
    # 
    # [:text] The text of the story. Maximum 300 characters.
    # [:url] The url for the currently logged-in user.
    #
    def comment(story, arg)
      raise FMyLife::AuthenticationError.new("You aren't logged in.") if @auth_token.nil?
      params = (arg.is_a? FMyLife::Comment) ? {:text => arg.text, :url => arg.author_url} : arg
      params[:id] = (story.is_a? FMyLife::Story) ? story.id : story
      params[:token] = @auth_token
      path = "/comment"
      doc = http_get(path, params)
      case code(doc)
      when 0
        raise VotingError.new("Error while voting on story ##{params[:id]}: #{error(doc)}")
      when 1
        true
      end
    end
    
    # Returns an FMyLife::Developer object with information on the current developer (determined
    # by the id provided when the FMyLife was instantiated)
    def developer_info
      path = "/dev"
      doc = http_get(path)
      case code(doc)
      when 0
        raise RetrievalError.new("Error retrieving developer info: #{error(doc)}")
      when 1
        Developer.new(:xml => doc)
      end
    end
    
    # Returns all unmoderated stories.
    def all_unmoderated
      path = "/mod/view"
      doc = http_get(path)
      results = []
      xpath(doc,"//items/item").each do |item|
        results << xml_content(item).to_i
      end
      results
    end
    
    # Returns a single unmoderated story, based on its ID number.
    def unmoderated(id)
      path = "/mod/view/#{id}"
      retrieve_stories(path, true)
    end
    
    # Returns the last story to be moderated.
    def last_moderated
      path = "/mod/last"
      retrieve_stories(path, true)
    end
    
    # Moderates a given story with a "yes" or "no" answer. ID can be either an FMyLife::Story object
    # or an ID number. +type+ should be :yes or :no .
    def moderate(story, type)
      raise VotingTypeError.new("Your vote must be either 'yes' or 'no'.") unless [:yes, :no].include? type.to_sym
      id = (story.is_a? Story) ? story.id : story
      path = "/mod/#{type}/#{id}"
      doc = http_get(path, :token => @auth_token)
      case code(doc)
      when 0
        raise VotingError.new("Error while moderating story ##{story.id}: #{error(doc)}")
      when 1
        true
      end
    end
    
    # Helper method for retreiving multiple stories, without comments. Internal Use Only.
    def retrieve_stories(path, pass_token = false, params = {})
      params.merge!({:token => @auth_token}) if pass_token
      doc = http_get(path, params)
      case code(doc)
      when 0
        raise FMyLife::RetrievalError.new("Error retrieving stories: #{error(doc)}")
      when 1
        stories = []
        xpath(doc,'//items/item').each do |entry|
          story = FMyLife::Story.new(:xml => entry)
          stories << story
        end
        stories
      end
    end
    
    # Helper method for retrieving URLs via GET while escaping parameters and including API-specific
    # parameters
    def http_get(path, query_params = {})
      query_params.merge!(:key => @api_key, :language => @language)
      http = Net::HTTP.new((@sandbox_mode) ? SANDBOX_ROOT : API_ROOT)
      path = path + "?" + URI.escape(query_params.map {|k,v| "#{k}=#{v}"}.join("&"), /[^-_!~*'()a-zA-Z\d;\/?:@&=+$,\[\]]/n)
      resp = http.get(path)
      xml_doc(resp.body)
    end
    
    # Helper method for retrieving URLs via POST while escaping parameters and including API-specific
    # parameters
    def http_post(path, data, query_params = {})
      query_params.merge!(:key => @api_key, :language => @language)
      http = Net::HTTP.new((@sandbox_mode) ? SANDBOX_ROOT : API_ROOT)
      path = path + "?" + URI.escape(query_params.map {|k,v| "#{k}=#{v}"}.join("&"), /[^-_!~*'()a-zA-Z\d;\/?:@&=+$,\[\]]/n)
      resp = http.post(path, data)
      xml_doc(resp.body)
    end
    

    
    # Helper method that finds the error code from an XML document from fmylife
    def code(doc)
      xml_content(xpath(doc,'//code').first).to_i
    end
    
    # Helper method that finds the error string from an XML document from fmylife
    def error(doc)
      begin
        xml_content xpath(doc,'//error').first
      rescue
        xml_content xpath(doc,'//errors').first
      end
    end
  end
  
  # = Story
  # Encapsulates a story on fmylife.com. These are primary used for reading stories
  # off the site, but it can be used to submit stories as well. An example:
  #
  #    fml = FMyLife.new("apikeyhere")
  #    story = FMyLife::Story.new(:author => "Anonymous", 
  #                                :category => :love,
  #                                :text => "blah blah blah. FML")
  #    fml.submit(story)
  #
  # To read one, simple use it's variables:
  #    story = fml.latest.first
  #    author = story.author
  #    text = story.text
  #
  class Story < XMLStruct
    attr_accessor :comments
    
    field :id, :attribute, "id", "."
    field :author, :node, "author"
    field :category, :node, "category"
    field :date, :proc, lambda { |entry| Time.xmlschema(xml_content(xpath(entry,"date").first)) }
    field :agreed, :node, "agree"
    field :deserved, :node, "deserved"
    field :num_comments, :node, "comments"
    field :text, :node, "text"
    field :comments_flag, :node, "comments_flag"
    
    # Initialize a new story. Available options are:
    #
    # [:author] The name of the author
    # [:category] The category (must be from FMyLife::AVAILABLE_CATEGORIES)
    # [:text] The text of the submissions
    def initialize(opts = {}); super(opts); end
  end
  
  # = Comment
  # Encapsulates a comment on fmylife.com. Belongs to a story. This class
  # can be used for submitting a comment, or for reading them. To submit one,
  # initialize them as follows:
  #
  #    comment = FMyLife::Comment.new(:text => "good story")
  #    fml.comment(story, comment)
  # 
  class Comment < XMLStruct
    field :id, :attribute, "id", "."
    field :order, :attribute, "pub_id", "."
    field :staff, :proc, Proc.new {|entry| (xml_attribute(entry,"staff").to_i == 1)}
    field :author, :node, "author"
    field :author_url, :attribute, "url", "author"
    field :date, :proc, lambda {|entry| Time.xmlschema(xml_content(xpath(entry,"date").first))}
    field :text, :node, "text"
    
    # Initialize a new comment. Available options are:
    #
    # [:text] The text of the submission
    #
    # All others will have no effect upon submitting the comment.
    def initialize(opts={}); super(opts); end
  end
  
  # = Developer
  #
  # This class holds the developer's information that one can request using the
  # FMyLife::Account#developer_info method. All information is read-only.
  #
  class Developer < XMLStruct
    field :name, :node, "//infos/name"
    field :project, :node, "//infos/project"
    field :description, :node, "//infos/description"
    field :url, :node, "//infos/url"
    field :email, :node, "//infos/mail"
    field :last24h, :node, "//actions/last24h"
    field :alltime, :node, "//actions/alltime"
    field :tokens, :node, "//tokens"
  end
end