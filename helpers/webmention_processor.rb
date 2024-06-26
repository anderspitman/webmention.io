class WebmentionProcessor
  begin
    include SuckerPunch::Job
  rescue NameError
  end

  # Run as a full thread instead of a fiber
  # See https://github.com/celluloid/celluloid/wiki/Fiber-stack-errors
  if method_defined? :task_class
    task_class TaskThread
  end

  def perform(event)
    process_mention event[:username], event[:source], event[:target], event[:protocol], event[:token], event[:code], event[:endpoint_type]
  end

  def error_status(token, source, target, protocol, error, error_description=nil)
    status = {
      :status => error,
      :source => source,
      :target => target
    }
    if error_description
      status[:summary] = error_description
    end
    WebmentionProcessor.stats_count @redis, token, protocol, error
    WebmentionProcessor.update_status @redis, token, status
  end

  def self.update_status(redis, token, data)
    redis.setex "webmention:status:#{token}", 86400*3, data.to_json
  end

  def self.stats_count(redis, token, protocol, key)
    redis.zadd "webmention.io:stats:#{protocol}:#{key}", Time.now.to_i, token
  end

  # Handles actually verifying source links to target, returning the list of errors based on the webmention errors
  def process_mention(username, source, target, protocol, token, code=nil, endpoint_type='account')
    @redis = Redis.new :host => SiteConfig.redis.host, :port => SiteConfig.redis.port

    target_account = Account.first :username => username
    if target_account.nil?
      error = 'target_not_found'
      error_status token, source, target, protocol, error
      return nil, error
    end
    if source == target
      error = 'invalid_target'
      error_status token, source, target, protocol, error
      return nil, error
    end

    #puts "Verifying link exists from #{source} to #{target}"

    begin
      target_uri = URI.parse(URI.escape(target))
      target_domain = target_uri.host
    rescue
      error = 'invalid_target'
      error_status token, source, target, protocol, error, 'target could not be parsed as a URL'
      return nil, error
    end

    if target_domain.nil?
      error = 'invalid_target'
      error_status token, source, target, protocol, error, 'target domain was empty'
      return nil, error
    end

    begin
      source_uri = URI.parse(URI.escape(source))
    rescue
      error = 'invalid_source'
      error_status token, source, target, protocol, error, 'source could not be parsed as a URL'
      return nil, error
    end

    # Check that the domain is not blocked
    block = target_account.blocks.first({domain: source_uri.host})
    if !block.nil?
      error = 'blocked'
      error_status token, source, target, protocol, error, 'source domain is blocked'
      return nil, error
    end

    site = Site.first :account => target_account, :domain => target_domain

    if site.nil?
      error = 'invalid_target'
      error_status token, source, target, protocol, error, 'target domain not found on this account'
      return nil, error
    end
    
    # Check that the source URL is not in the blocklist
    bl = Blocklist.first :site => site, :source => source
    if !bl.nil?
      error = 'blocked'
      error_status token, source, target, protocol, error, 'source URL is blocked'
      return nil, error
    end
    
    source_data = nil

    # Private Webmentions
    if code
      puts "Trying to obtain an access token for the private webmention..."
      access_token = XRay.get_access_token source, code
      if access_token
        if access_token.class == XRayError
          error_status token, source, target, protocol, access_token.error, access_token.error_description
          return nil, access_token.error
        elsif access_token['access_token']
          puts "\taccess token: #{access_token['access_token']}"
          source_data = XRay.parse source, target, false, access_token['access_token']
        end
      else
        error = 'access_token_error'
        error_status token, source, target, protocol, error, 'Error obtaining an access token, no access token returned.'
        return nil, error
      end
    else
      source_data = XRay.parse source, target
    end


    if source_data.nil?
      error = 'invalid_source'
      error_status token, source, target, protocol, error, 'Error retrieving source. No result returned from XRay.'
      return nil, error
    end


    debug = Debug.all(:page_url => target, :enabled => true) | Debug.all(:domain => target_domain, :enabled => true)
    if debug.count > 0
      puts "Debug enabled for #{target}"
      filename = File.join(File.expand_path(File.dirname(__FILE__)), '../debug.log')
      log = Logger.new(filename)
      log.debug "==================================================="
      log.debug "Webmention from #{source} to #{target}"
      log.debug source_data.to_json
      begin
        # Fetch the content and write it to the log
        debug_content = HTTParty.get source
        log.debug debug_content.response.body
      rescue => e
      end
    end


    if source_data.class == XRayError
      if source_data.error != "no_link_found"
        # Don't log these errors
        puts "\tError retrieving source: #{source_data.error} : #{source_data.error_description}"
      end

      # Check for an existing post that has been deleted
      site = Site.first :account => target_account, :domain => target_domain
      if site
        page = Page.first :site => site, :href => target
        if page
          link = Link.first :page => page, :href => source
          if link
            # This webmention was previously received, but now was deleted, so delete from the DB
            link.destroy

            # And respond with a success
            WebmentionProcessor.update_status @redis, token, {
              :status => 'deleted',
              :source => source,
              :target => target,
              :private => link.is_private,
            }

            WebHooks.deleted site, source, target, (code ? true : false)

            return nil, 'deleted'
          end
        end
      end

      error_status token, source, target, protocol, source_data.error, source_data.error_description
      return nil, source_data.error
    end



    puts "Processing... s=#{source} t=#{target}"


    debug = Debug.all(:page_url => target, :on_success => true) | Debug.all(:domain => target_domain, :on_success => true)
    if debug.count > 0
      puts "Debug success enabled for #{target}"
      filename = File.join(File.expand_path(File.dirname(__FILE__)), '../debug.log')
      log = Logger.new(filename)
      log.debug "==================================================="
      log.debug "Webmention successful from #{source} to #{target}"
      log.debug source_data.to_json
      begin
        # Fetch the content and write it to the log
        debug_content = HTTParty.get source
        log.debug debug_content.response.body
      rescue => e
      end
    end


    # If the page already exists, use that record. Otherwise create it and find out what kind of object is on the page.
    # This currently uses the Ruby mf2 parser to parse the target URL
    page = create_page_in_site site, target

    link = Link.first_or_create({
      :page => page,
      :href => source
    }, {
      :site => site,
      :account => site.account, 
      :domain => source_uri.host,
    })

    link.protocol = protocol
    link.endpoint_type = endpoint_type

    already_registered = link[:verified]

    # Parse for microformats and look for "like", "invite", "rsvp", or other post types
    parsed = false
    source_is_bridgy = source.start_with? 'https://www.brid.gy/', 'https://brid.gy', 'https://brid-gy.appspot.com/'

    begin
      add_author_to_link source_data, link
      add_mf2_data_to_link source_data, link

      # Detect post type (reply, like, reshare, RSVP, mention) and silo and
      # generate custom notification message.
      url = !link.url.blank? ? link.url : source

      set_type source_data, link, source, target
    rescue => e
      # Ignore errors trying to parse for upgraded microformats
      puts "Error while parsing microformats #{e.message}"
      puts e.backtrace
    end

    WebHooks.notify site, link, source, target, (code ? true : false)

    if !site.account.aperture_uri.empty?
      begin
        puts "Posting to Aperture"

        aperture_data = source_data

        # override if XRay parsing failed
        aperture_data['url'] = source if (aperture_data['url'].nil? or aperture_data['url'].empty?)
        aperture_data['published'] = DateTime.now.to_s if (aperture_data['published'].nil? or aperture_data['published'].empty?)

        # this might need to change to something more specific to indicating why the webmention is relevant
        aperture_data['in-reply-to'] = [target] if (aperture_data['in-reply-to'].nil? or aperture_data['in-reply-to'].empty?)

        puts aperture_data.to_json

        puts RestClient.post site.account.aperture_uri, aperture_data.to_json, {
          :Authorization => "Bearer #{site.account.aperture_token}",
          :'Content-Type' => 'application/jf2+json'
        }
      rescue => e
        # ignore errors sending to Aperture
      end
    end

    puts "\tfinished #{token}"

    link.token = token
    link.verified = true

    # If a code was sent with the webmention, record that the post is private
    link.is_private = code ? true : false

    link.save

    WebmentionProcessor.update_status @redis, token, {
      :status => 'success',
      :source => source,
      :target => target,
      :private => link.is_private,
      :data => Formats.build_jf2_from_link(link)
    }

    WebmentionProcessor.stats_count @redis, token, protocol, 'success'

    return link, 'success'
  end

  def create_page_in_site(site, target)
    page = Page.first :site => site, :href => target
    if page.nil?
      page = Page.new
      page.site = site
      page.account = site.account
      page.href = target
      page.save # save the page now since XRay may take a while to return

      begin
        page_data = XRay.parse target

        if page_data.nil?
          puts "No data returned from XRay for #{target}"
        else
          if page_data.class == XRayError
            puts "\tError retrieving page: #{page_data.error} : #{page_data.error_description}"
          else
            # Determine the type of page the target is. It might be an event or a photo for example
            if page_data['type'] == 'entry'
              page.type = 'entry'

              if page_data['photo']
                page.type = 'photo'
              elsif page_data['video']
                page.type = 'video'
              elsif page_data['audio']
                page.type = 'audio'
              end

            elsif page_data['type'] == 'event'
              page.type = 'event'
            end

            if page_data['name']
              page.name = page_data['name']
            end
          end
        end
      rescue => e
        puts "Error parsing: #{e.inspect}"
        puts e.backtrace
      end

      page.save
    end
    page
  end

  def set_type(entry, link, source, target)
    url = !link.url.blank? ? link.url : source
    source_is_twitter = url.start_with? 'https://twitter.com/'
    source_is_gplus = url.start_with? 'https://plus.google.com/'

    if rsvp = entry['rsvp']
      rsvp = rsvp.downcase
      link.type = "rsvp-#{rsvp}"

    elsif entry['invitee']
      link.type = "invite"

    elsif repost_of = entry['repost-of']
      if !repost_of.include? target
        # for bridgy
        # TODO: when the repost-of link is not the one receiving the webmention, "that linked to" is not necessarily correct
        # It's only correct when the target URL is in the contents of the repost, e.g. if the repost included all the contents of the original
        link.is_direct = false
      end
      link.type = "repost"

    elsif like_of = entry['like-of']
      if !like_of.include? target
        # for bridgy
        link.is_direct = false
      end
      link.type = "like"

    elsif bookmark_of = entry['bookmark-of']
      if !bookmark_of.include? target
        # for bridgy
        link.is_direct = false
      end
      link.type = "bookmark"

    elsif in_reply_to = entry['in-reply-to']
      if !in_reply_to.include? target
        # for bridgy
        link.is_direct = false
      end
      link.type = "reply"

    else
      link.type = "link"
    end

    link.save
  end

  def add_author_to_link(entry, link)
    link.author_url = ""
    link.author_name = ""
    link.author_photo = ""

    # kinda a hack for bridgy invites
    if entry && entry['invitee']
      link.author_url = entry['invitee'][0]
    end

    if entry && entry['author'] && entry['author']['type'] == 'card'
      link.author_url = entry['author']['url'] if entry['author']['url']
      link.author_name = entry['author']['name'] if entry['author']['name']
      link.author_photo = entry['author']['photo'] if entry['author']['photo']
      if link.site.archive_avatars && link.author_photo
        # Replace the author photo with an archive URL
        archive_photo_url = Avatar.get_avatar_archive_url link.author_photo
        link.author_photo = archive_photo_url
      end
      link.save
    end
  end

  def add_mf2_data_to_link(entry, link)
    link.url = entry['url']
    link.name = entry['name']

    if entry['summary']
      link.summary = entry['summary']
    end

    if entry['content']
      if entry['content']['html']
        link.content = entry['content']['html']
      end
      link.content_text = entry['content']['text']
    end

    if !link.url.blank?
      # Set link.url relative to source URL from the webmention
      link.url = AbsoluteUri::AbsoluteUri.new(link.url, base: link.href).absolutize
    end

    link.photo = entry['photo'].to_json if entry['photo']
    link.video = entry['video'].to_json if entry['video']
    link.audio = entry['audio'].to_json if entry['audio']

    published = entry['published']
    if !published.blank?
      date = DateTime.parse(published.to_s)
      link.published = date.to_time.utc # Convert to UTC (uses ENV timezone)
      # only set the timezone offset if it was provided in the original publish date string
      if published.to_s.match(/[+-]\d{2}:?\d{2}/)
        link.published_offset = date.to_time.utc_offset
      end
      link.published_ts = date.to_time.to_i # store UTC unix timestamp
    end

    syndications = entry['syndication']
    if !syndications.blank?
      link.syndication = syndications.to_json
    end

    if entry['swarm-coins']
      link.swarm_coins = entry['swarm-coins'].to_i
    end

    if !entry['rels'].blank? && !entry['rels']['canonical'].blank?
      link.relcanonical = entry['rels']['canonical']
    end

    link.save
  end

  def maybe_get(obj, method)
    begin
      obj.send method
    rescue
      nil
    end
  end

end
