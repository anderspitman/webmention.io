class Account
  include DataMapper::Resource
  property :id, Serial

  property :username, String, :length => 255
  property :domain, String, :length => 255
  property :email, String, :length => 255

  property :xmpp_to, String, :length => 255
  property :xmpp_user, String, :length => 255
  property :xmpp_password, String, :length => 255
  property :tiktokbot_uri, String, :length => 255
  property :tiktokbot_token, String, :length => 255
  property :aperture_uri, String, :length => 255
  property :aperture_token, String, :length => 255

  has n, :sites
  has n, :links
  has n, :blocks

  property :token, String, :length => 255
  
  property :pingback_enabled, Boolean, :default => 0

  property :created_at, DateTime
  property :updated_at, DateTime
  property :last_login, DateTime

  def generate_new_token!
    self.token = SecureRandom.urlsafe_base64 16
    self.save
  end

end
