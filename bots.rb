require 'twitter_ebooks'
require 'ostruct'
require 'open-uri'
require 'json'

require_relative 'tweetpic'

# Module used to extend string with helper functions
module PuddiString
  # Trim a string, optionally adding a thing at the end.
  def trim(len)
    # Just call the other function.
    trim_cap(len, '')
  end
  def trim_ellipsis(len)
    # Special one for this hard to find character
    trim_cap(len, '…')
  end
  def trim_cap(len, cap)
    # Make sure inputs are the right type.
    len = len.to_i
    cap = cap.to_s
    # First, check if the string is already within the length.
    return self if length <= len
    # It's not, so find out how short we have to trim to.
    real_length = len - cap.length

    # Are we trimming to nothing?
    if real_length < 1
      # Does cap fit in remaining length?
      if cap.length == len
        return cap
      else
        return ''
      end
    end

    # Now just return the trimmed string!
    self[0...real_length] + cap
  end
end

# Module used to extend Ebooks with Danbooru features
module Danbooru
  # Default danbooru request parameters
  attr_reader :danbooru_default_params

  # Initialization for danbooru methods
  def danbooru_configure
    # Setup default danbooru params with danbooru login info
    @danbooru_default_params = {}
    unless config.danbooru_login.empty? && config.danbooru_key.empty?
      @danbooru_default_params['login'] = config.danbooru_login
      @danbooru_default_params['api_key'] = config.danbooru_api_key
    end

    # Populate history
    danbooru_populate_history
  end

  # Populate post history from twitter
  def danbooru_populate_history(tweet_count = 200)
    # Get past tweets
    my_tweets = twitter.user_timeline username, count: tweet_count

    # Iterate through them, adding them to history if they contain a danbooru uri
    my_tweets.each do |tweet|
      # Loop through each tweet's uri
      tweet.uris.each do |uri|
        if match_data = uri.expanded_url.to_s.match(%r //danbooru\.donmai\.us/posts/(?<post_id>\d+) i)
          # If it matches, add it to history
          danbooru_history_add match_data['post_id']
        end
      end
    end
  end

  # Add a post id to history
  def danbooru_history_add(post_id)
    # Create a history array if it doesn't already exist
    @danbooru_post_history ||= []

    post_id = [post_id.to_i]

    # Convert it to an integer and then add it
    @danbooru_post_history |= post_id

    post_id
  end

  # Check if a post id is in history
  def danbooru_history_include?(post_id)
    return false unless defined? @danbooru_post_history

    @danbooru_post_history.include? post_id.to_i
  end

  # Wrapper for danbooru requests
  def danbooru_get(query = 'posts', parameters = {})
    query ||= posts
    parameters ||= {}

    # Begin generating a URI
    uri = "https://danbooru.donmai.us/#{query}.json"

    # Add default parameters to parameters
    parameters = danbooru_default_params.merge parameters

    # Loop through parameters if necessary
    unless parameters.empty?
      uri += '?'
      # Create an array of parameters
      parameters_array = []
      parameters.each do |key, value|
        # Convert key to a string if it's a symbol
        parameters_array << "#{URI.escape key.to_s}=#{URI.escape value.to_s}"
      end
      # Merge them and add them to uri
      uri += parameters_array.join ';'
    end

    # Access URI and convert data from json
    begin
      open uri do |io|
        JSON.parse io.read
      end
    rescue => error
      log "Error while fetching data (#{error.class.to_s}): #{error.message}\n" + error.backtrace.join("\n")
      {}
    end
  end

  # Fetch posts from danbooru
  def danbooru_posts(tags = config.tags, page = 1)
    tags ||= config.tags
    page ||= 1

    danbooru_get 'posts', page: page, limit: 100, tags: tags
  end

  # Genreates a little string to tweet with links.
  def danbooru_tag_string(post)
    # Convert a string with just spaces into a friendly comma separated form with ands.
    def get_tag_string(spaced_string, remove_quotes = false)
      working_array = spaced_string.split ' '
      if remove_quotes
        working_array.map! do |string|
          str = string.gsub(/_\(.*\z/, '')
          str.gsub(/_/, ' ')
        end
      else
        working_array.map! do |string|
          string.gsub(/_/, ' ')
        end
      end

      case working_array.length
      when 0
        nil
      when 1
        working_array[0]
      when 2
        working_array.join ' and '
      else
        working_array[-1] = 'and ' + working_array[-1]
        working_array.join ', '
      end
    end

    # Generate tag strings
    tags_character = get_tag_string post.tag_string_character, true
    tags_copyright = get_tag_string post.tag_string_copyright
    tags_artist = get_tag_string post.tag_string_artist

    output = ''
    if tags_character.nil?
      if tags_copyright.nil?
        # No character or copyright
        output = 'drawn'
      else
        # No character, but has copyright
        output = tags_copyright
      end
    else
      # Has characters
      output = tags_character
      unless tags_copyright.nil?
        output += " (#{tags_copyright})"
      end
    end

    output += ' by ' + tags_artist unless tags_artist.nil?

    output
  end

  # Tweet a post with its post data
  def danbooru_tweet_post(post)
    # Make post an OpenStruct
    unless post.is_a? OpenStruct
      post = post[0] if post.is_a? Array
      post = danbooru_get("posts/#{post}") unless post.is_a? Hash
      # Ensure that it contains an id.
      return unless post.has_key? 'id'
      post = OpenStruct.new post
    end

    # Is post deleted, and we don't want deleted posts?
    return false if config.no_deleted && post.is_deleted

    # Is post in a format we like?
    return false unless ['jpg','jpeg','png'].include? post.file_ext

    # Is it sensitive?
    sensitive = post.rating != 's'

    # Get a tag string
    tag_string = danbooru_tag_string post
    tag_string.extend PuddiString
    # 93 = 140 - 2 (spaces) - 23 (https url) - 22 (http url)
    tag_string = ' ' + tag_string.trim_ellipsis(93) unless tag_string.empty?

    # Get post URI
    post_uri = "https://danbooru.donmai.us/posts/#{post.id}"

    # Get image URI
    image_uri = "https://danbooru.donmai.us#{post.large_file_url}"

    # Tweet post!
    log "Tweeting post #{post.id}, rating: #{post.rating}"
    begin
      pic_tweet("#{post_uri}#{tag_string}", image_uri, possibly_sensitive: sensitive)
    rescue => error
      log "Error while tweeting (#{error.class.to_s}): #{error.message}\n" + error.backtrace.join("\n")
      false
    else
      true
    end
  end

  # Pick and tweet a post based on tag settings.
  def danbooru_select_and_tweet_post
    # Everyone hates catching, but it seems more elegant than a done variable.
    catch :success do
      # Create variable to hold current page
      search_page = 0
      loop do
        # Increment search_page
        search_page += 1
        # Fetch posts
        posts = danbooru_posts(config.tags, search_page)
        # Just break if we don't have posts
        break if posts.empty?
        # Now loop down each post, attempting to post it.
        posts.each do |post|
          post = OpenStruct.new post

          # Skip this post if it's already in our history
          next if danbooru_history_include? post.id
          # Add post to history, since we've seen it now
          danbooru_history_add post.id

          # Attempt to tweet post, heading to next one if it didn't work
          next unless danbooru_tweet_post post
          # It worked!
          throw :success
        end
      end
    end
  end
end

module Biotags
  # Update @config
  def biotags_update
    # Fetch twitter description and grab its biotags
    if match_data = user.description.match(/@_dbooks/i)
      config match_data.post_match
    end
  end

  # Create an OpenStruct from parsing input string, if one is given
  def config(biotag_string = nil)
    # Return config if no string is given, or if string is identical to last one.
    # If config isn't defined, re-call this method with an empty string.
    return @config || config('') unless biotag_string.is_a? String
    return @config if biotag_string == @biotag_string_previous

    # Save string for comparison next time
    @biotag_string_previous = biotag_string
    # Create new @config
    @config = OpenStruct.new
    # Create a tags array to hold tags for now
    tags_array = []

    # Prepend default and env var variables, then iterate through them
    "#{CONFIG_DEFAULT} #{ENV['DBOOKS']} #{biotag_string}".split(' ').each do |item|
      # Is it a biotag?
      if item.start_with? '%'
        # It is. Remove identifier
        item = item[1..-1]
      else
        # It isn't. Make it one.
        item = "tags:#{item}"
      end

      # Is it a key/value?
      if match_data = item.match(/:/)
        key = match_data.pre_match
        value = match_data.post_match
      else
        key = item
        value = true
      end

      # Add it to @config!
      if key == 'tags'
        tags_array |= [value]
      else
        # Convert all non-word characters in key to underscores
        key.gsub!(/\W/,'_')

        @config[key] = value
      end
    end

    # Move tags_array into @config
    @config.tags = tags_array.join(' ')

    # Done!
    @config
  end

  # Default config options
  CONFIG_DEFAULT = '%every:30m'
end

# Main twitterbot class
class DbooksBot < Ebooks::Bot
  include Danbooru, Biotags

  # Current user data
  attr_reader :user

  # Inital twitterbot setup
  def configure
    # Load configuration into twitter variables
    @consumer_key = config.twitter_key
    @consumer_secret = config.twitter_secret
    @access_token = config.twitter_token
    @access_token_secret = config.twitter_token_secret

    danbooru_configure

    if access_token && access_token_secret && consumer_key && consumer_secret
      update_user
      scheduler.every '5m' do
        update_user
      end
    end
  end

  # Update @user. In a separate function because configure needs it twice
  def update_user(current_user = twitter.user)
    current_user = twitter.user unless current_user.is_a? Twitter::User
    @user = current_user

    # Update username
    @username = user.screen_name
    # Update config
    biotags_update

    # Update tweet timer
    manage_tweet_timer if @tweet_timer
  end

  # Listen in on events
  alias_method :dbooks_override_receive_event, :receive_event
  def receive_event(event)
    # Intercept events about myself to update myself
    case event
    when Twitter::Tweet
      update_user event.user if event.user.id == user.id
    when Twitter::DirectMessage
      if event.recipient.id == user.id
        update_user event.recipient
      elsif event.sender.id == user.id
        update_user event.sender
      end
    else
      if event.respond_to? :name
        if event.source.id == user.id
          update_user event.source
        elsif event.target.id == user.id
          update_user event.target
        end
      end
    end

    # Call original method
    dbooks_override_receive_event event
  end

  # If the tweet timer isn't running at the desired speed, edit it.
  def manage_tweet_timer(options = {})
    # Return if everything is fine
    if @tweet_timer
      return if @tweet_timer.original == config.every

      # Delete old @tweet_timer
      @tweet_timer.unschedule
    end

    begin
      # Repeat this, saving it as a new @tweet_timer
      @tweet_timer = scheduler.schedule_every config.every, options do
        # Call myself to check if changes are needed
        manage_tweet_timer
        danbooru_select_and_tweet_post
      end
      log @tweet_timer.original
    rescue ArgumentError
      # config.every is invalid!
      config.every = '30m'
      # Call myself again now that config.every is fixed.
      manage_tweet_timer
    end
  end

  # When twitter bot starts up
  def on_startup
    # Post first tweet instantly.
    manage_tweet_timer first: :now
  end
end

# Make DbooksBot!
DbooksBot.new ''
