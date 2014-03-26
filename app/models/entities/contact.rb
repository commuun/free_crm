# Copyright (c) 2008-2013 Michael Dvorkin and contributors.
#
# Fat Free CRM is freely distributable under the terms of MIT license.
# See MIT-LICENSE file or http://www.opensource.org/licenses/mit-license.php
#------------------------------------------------------------------------------
# == Schema Information
#
# Table name: contacts
#
#  id              :integer         not null, primary key
#  user_id         :integer
#  reports_to      :integer
#  first_name      :string(64)      default(""), not null
#  last_name       :string(64)      default(""), not null
#  access          :string(8)       default("Public")
#  title           :string(64)
#  department      :string(64)
#  source          :string(32)
#  email           :string(64)
#  alt_email       :string(64)
#  phone           :string(32)
#  mobile          :string(32)
#  fax             :string(32)
#  blog            :string(128)
#  linkedin        :string(128)
#  facebook        :string(128)
#  twitter         :string(128)
#  born_on         :date
#  do_not_call     :boolean         default(FALSE), not null
#  deleted_at      :datetime
#  created_at      :datetime
#  updated_at      :datetime
#  background_info :string(255)
#  skype           :string(128)
#

class Contact < ActiveRecord::Base
  belongs_to  :user
  belongs_to  :reporting_user, :class_name => "User", :foreign_key => :reports_to
  has_one     :account_contact, :dependent => :destroy
  has_one     :account, :through => :account_contact
  has_one     :business_address, :dependent => :destroy, :as => :addressable, :class_name => "Address", :conditions => "address_type = 'Business'"
  has_many    :addresses, :dependent => :destroy, :as => :addressable, :class_name => "Address" # advanced search uses this
  has_many    :emails, :as => :mediator

  has_ransackable_associations %w(account tags activities emails addresses comments)
  ransack_can_autocomplete

  serialize :subscribed_users, Set

  accepts_nested_attributes_for :business_address, :allow_destroy => true, :reject_if => proc {|attributes| Address.reject_address(attributes)}

  scope :created_by,  ->(user) { where( user_id: user.id ) }

  scope :text_search, ->(query) {
    t = Contact.arel_table
    # We can't always be sure that names are entered in the right order, so we must
    # split the query into all possible first/last name permutations.
    name_query = if query.include?(" ")
      scope, *rest = query.name_permutations.map{ |first, last|
        t[:first_name].matches("%#{first}%").and(t[:last_name].matches("%#{last}%"))
      }
      rest.map{|r| scope = scope.or(r)} if scope
      scope
    else
      t[:first_name].matches("%#{query}%").or(t[:last_name].matches("%#{query}%"))
    end

    other = t[:email].matches("%#{query}%").or(t[:alt_email].matches("%#{query}%"))
    other = other.or(t[:phone].matches("%#{query}%")).or(t[:mobile].matches("%#{query}%"))

    where( name_query.nil? ? other : name_query.or(other) )
  }

  uses_user_permissions
  acts_as_commentable
  uses_comment_extensions
  acts_as_taggable_on :tags
  has_paper_trail :ignore => [ :subscribed_users ]

  has_fields
  exportable
  sortable :by => [ "first_name ASC",  "last_name ASC", "created_at DESC", "updated_at DESC" ], :default => "created_at DESC"

  validates_presence_of :first_name, :message => :missing_first_name, :if => -> { Setting.require_first_names }
  validates_presence_of :last_name,  :message => :missing_last_name,  :if => -> { Setting.require_last_names  }
  validate :users_for_shared_access

  # Default values provided through class methods.
  #----------------------------------------------------------------------------
  def self.per_page ; 20                  ; end
  def self.first_name_position ; "before" ; end

  #----------------------------------------------------------------------------
  def full_name(format = nil)
    if format.nil? || format == "before"
      "#{self.first_name} #{self.last_name}"
    else
      "#{self.last_name}, #{self.first_name}"
    end
  end
  alias :name :full_name

  # Backend handler for [Create New Contact] form (see contact/create).
  #----------------------------------------------------------------------------
  def save_with_account_and_permissions(params)
    save_account(params)
    result = self.save
    result
  end

  # Backend handler for [Update Contact] form (see contact/update).
  #----------------------------------------------------------------------------
  def update_with_account_and_permissions(params)
    save_account(params)
    # Must set access before user_ids, because user_ids= method depends on access value.
    self.access = params[:contact][:access] if params[:contact][:access]
    self.attributes = params[:contact]
    self.save
  end

  # Attach given attachment to the contact if it hasn't been attached already.
  #----------------------------------------------------------------------------
  def attach!(attachment)
    unless self.send("#{attachment.class.name.downcase}_ids").include?(attachment.id)
      self.send(attachment.class.name.tableize) << attachment
    end
  end

  # Discard given attachment from the contact.
  #----------------------------------------------------------------------------
  def discard!(attachment)
    self.send(attachment.class.name.tableize).delete(attachment)
  end

  private
  # Make sure at least one user has been selected if the contact is being shared.
  #----------------------------------------------------------------------------
  def users_for_shared_access
    errors.add(:access, :share_contact) if self[:access] == "Shared" && !self.permissions.any?
  end

  # Handles the saving of related accounts
  #----------------------------------------------------------------------------
  def save_account(params)
    if params[:account][:id] == "" || params[:account][:name] == ""
      self.account = nil
    else
      account = Account.create_or_select_for(self, params[:account])
      if self.account != account and account.id.present?
        self.account_contact = AccountContact.new(:account => account, :contact => self)
      end
    end
    self.reload unless self.new_record? # ensure the account association is updated
  end

  ActiveSupport.run_load_hooks(:fat_free_crm_contact, self)
end
