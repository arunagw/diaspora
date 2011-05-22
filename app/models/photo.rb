#   Copyright (c) 2009, Diaspora Inc.  This file is
#   licensed under the Affero General Public License version 3 or later.  See
#   the COPYRIGHT file.

class Photo < ActiveRecord::Base
  require File.join(Rails.root, 'lib/diaspora/web_socket')
  include ApplicationHelper
  include ROXML
  include Diaspora::Webhooks
  include Diaspora::Guid
  include Diaspora::Socketable
  require 'carrierwave/orm/activerecord'
  mount_uploader :processed_image, ProcessedImage
  mount_uploader :unprocessed_image, UnprocessedImage

  xml_attr :diaspora_handle
  xml_attr :public
  xml_attr :created_at
  xml_attr :remote_photo_path
  xml_attr :remote_photo_name

  xml_attr :text
  xml_attr :status_message_guid

  belongs_to :status_message
  belongs_to :author, :class_name => 'Person'

  attr_accessible :text, :pending
  validate :ownership_of_status_message

  before_destroy :ensure_user_picture
  after_create :queue_processing_job

  def ownership_of_status_message
    message = StatusMessage.find_by_id(self.status_message_id)
    if status_message_id && message
      self.author_id == message.author_id
    else
      true
    end
  end
  def diaspora_handle= nd
    self.author = Person.where(:diaspora_handle => nd).first
    write_attribute(:diaspora_handle, nd)
  end

  def self.diaspora_initialize(params = {})
    photo = self.new params.to_hash
    photo.author = params[:author]
    photo.public = params[:public] if params[:public]
    photo.pending = params[:pending] if params[:pending]
    photo.diaspora_handle = photo.author.diaspora_handle
    image_file = params.delete(:user_file)
    photo.random_string = ActiveSupport::SecureRandom.hex(10)
    photo.unprocessed_image.store! image_file
    photo.update_remote_path
    photo
  end

  def not_processed?
    processed_image.path.nil?
  end

  def processed?
    !processed_image.path.nil?
  end

  def update_remote_path
    unless self.unprocessed_image.url.match(/^https?:\/\//)
      pod_url = AppConfig[:pod_url].dup
      pod_url.chop! if AppConfig[:pod_url][-1,1] == '/'
      remote_path = "#{pod_url}#{self.unprocessed_image.url}"
    else
      remote_path = self.unprocessed_image.url
    end

    name_start = remote_path.rindex '/'
    self.remote_photo_path = "#{remote_path.slice(0, name_start)}/"
    self.remote_photo_name = remote_path.slice(name_start + 1, remote_path.length)
  end

  def status_message_guid
    if self.status_message
      self.status_message.guid
    else
      nil
    end
  end

  def status_message_guid= new_sm_guid
    self.status_message= StatusMessage.where(:guid => new_sm_guid).first
  end

  def url(name = nil)
    if remote_photo_path
      name = name.to_s + '_' if name
      remote_photo_path + name.to_s + remote_photo_name
    elsif not_processed?
      unprocessed_image.url(name)
    else
      processed_image.url(name)
    end
  end

  def ensure_user_picture
    profiles = Profile.where(:image_url => url(:thumb_large))
    profiles.each { |profile|
      profile.image_url = nil
      profile.save
    }
  end

  def thumb_hash
    {:thumb_url => url(:thumb_medium), :id => id, :album_id => nil}
  end

  def queue_processing_job
    Resque.enqueue(Job::ProcessPhoto, self.id)
  end

  def process
    return false if self.processed? || (!unprocessed_image.path.nil? && unprocessed_image.path.include?('.gif'))
    processed_image.store!(unprocessed_image) #Ultra naive
    save!
  end

  def mutable?
    true
  end

  def as_json(opts={})
    {
    :photo => {
      :id => self.id,
        :url => self.url,
        :thumb_small => self.url(:thumb_small),
        :text => self.text
      }
    }
  end

  scope :on_statuses, lambda { |post_ids|
    where(:status_message_id => post_ids)
  }
  def subscribers(user)
    if self.public?
      user.contact_people
    else
      user.people_in_aspects(user.aspects_with_post(self.id))
    end
  end

  def receive(user, person)
    #exists locally, but you dont know about it
    #does not exsist locally, and you dont know about it
    #exists_locally?
    #you know about it, and it is mutable
    #you know about it, and it is not mutable

    local_post = Post.where(:guid => self.guid).first
    if local_post && local_post.author_id == self.author_id
      known_post = user.visible_posts.where(:guid => self.guid).first
      if known_post
        if known_post.mutable?
          known_post.update_attributes(self.attributes)
        else
          Rails.logger.info("event=receive payload_type=#{self.class} update=true status=abort sender=#{self.diaspora_handle} reason=immutable existing_post=#{known_post.id}")
        end
      else
        user.contact_for(person).receive_post(local_post)
        user.notify_if_mentioned(local_post)
        Rails.logger.info("event=receive payload_type=#{self.class} update=true status=complete sender=#{self.diaspora_handle} existing_post=#{local_post.id}")
        return local_post
      end
    elsif !local_post
      if self.save
        user.contact_for(person).receive_post(self)
        user.notify_if_mentioned(self)
        Rails.logger.info("event=receive payload_type=#{self.class} update=false status=complete sender=#{self.diaspora_handle}")
        return self
      else
        Rails.logger.info("event=receive payload_type=#{self.class} update=false status=abort sender=#{self.diaspora_handle} reason=#{self.errors.full_messages}")
      end
    else
      Rails.logger.info("event=receive payload_type=#{self.class} update=true status=abort sender=#{self.diaspora_handle} reason='update not from post owner' existing_post=#{self.id}")
    end
  end

  def activity_streams?
    false
  end
end
