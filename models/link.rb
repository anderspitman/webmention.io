class Link
  include DataMapper::Resource
  property :id, Serial

  property :href, String, :length => 512
  property :domain, String, :length => 256, :index => true
  property :verified, Boolean
  property :token, String, :length => 20, :index => true
  property :is_private, Boolean, :default => false

  property :html, Text
  property :url, String, :length => 256
  property :author_url, String, :length => 256
  property :author_name, String, :length => 256
  property :author_photo, String, :length => 256
  property :name, Text
  property :summary, Text
  property :content, Text
  property :content_text, Text

  property :photo, Text
  property :video, Text
  property :audio, Text

  property :published, DateTime
  property :published_offset, Integer
  property :published_ts, Integer
  property :syndication, Text
  property :swarm_coins, Integer

  property :type, String
  property :is_direct, Boolean, :default => true

  belongs_to :page
  belongs_to :site
  belongs_to :account

  property :deleted, Boolean, :default => false

  property :protocol, String, :length => 30 # webmention or pingback
  property :endpoint_type, String, :length => 30 # account or site

  property :relcanonical, String, :length => 255

  property :created_at, DateTime
  property :updated_at, DateTime

  def has_author_info
    !author_name.blank? || !author_url.blank? || !author_photo.blank?
  end

  def syndications
    return nil if syndication.blank?
    return JSON.parse syndication
  end

  def published_date
    return nil if published.blank?
    date = published
    if !published_offset.nil?
      date = date.new_offset(Rational(published_offset, 86400))
    end
    date
  end

  def absolute_url
    if url.blank?
      href
    else
      AbsoluteUri::AbsoluteUri.new(url, base: href).absolutize
    end
  end

  def source
    self.href
  end

  def source_id
    self.id
  end

  def target
    self.page.href
  end

  def target_id
    self.page.id
  end

  def mf2_relation_class
    case self.type
    when 'repost'
      'u-repost-of'
    when 'like'
      'u-like-of'
    when 'reply'
      'u-in-reply-to'
    when 'bookmark'
      'u-bookmark-of'
    else
      'u-mention-of'
    end
  end
end
