# encoding: utf-8
# PGonror is the corporate web site framework of Le Parti de Gauche based on Ruby on Rails.
# 
# Copyright (C) 2013 Le Parti de Gauche
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
# 
# See doc/COPYRIGHT.rdoc for more details.
class ArticlesController < ApplicationController
  before_filter :authenticate_user!
  before_filter :authenticate_publisher!
  before_filter :authenticate_administrator!, :only => [:destroy]
  before_filter :find, :only => [:show, :update, :destroy]
  before_filter :load_side_data, :only => [:new, :new_child, :create, :edit, :update]
  before_filter :pre_control_authorization, :only => [:new]
  cache_sweeper :article_sweeper, :only => [:create, :update, :destroy]

  # Index page.
  def index
    prepare_index
    reset_backtrace
    save_backtrace
  end

  # Triggers article search.
  def search
    prepare_index
    render :partial => "search_list"
  end

  # Searches articles for the panel bar.
  def panel_search
    @page_searched_articles = params[:page].present? ? params[:page].to_i : 1
    @searched_articles = Article.find_by_criteria({:search => params[:panel_search],
                                                   :category => params[:category_panel_search],
                                                   :parent => params[:parent_panel_search],
                                                   :exclude_status => Article::OFFLINE}, @page_searched_articles)
    @pages_searched_articles = Article.count_pages_by_criteria({:search => params[:panel_search],
                                                                :category => params[:category_panel_search],
                                                                :parent => params[:parent_panel_search],
                                                                :exclude_status => Article::OFFLINE})
    @parent_article = Article.find_by_id(params[:parent_panel_search]) unless params[:parent_panel_search].blank?
    @parent_parent_article = Article.find_by_id(@parent_article.parent_id) unless @parent_article.blank?
    session[:panel_search] = params[:panel_search]
    session[:category_panel_search] = params[:category_panel_search]
    session[:parent_panel_search] = params[:parent_panel_search]
    render :partial => "panel_search_list"
  end

  # Searches articles for the panel bar.
  def panel_search_page
    panel_search
  end

  # Shows an article.
  def show
    @uploaded_image = Article.new
    @uploaded_document = Article.new
    @parent_page = params[:parent_page].present? ? params[:parent_page].to_i : 1
    @source_page = params[:source_page].present? ? params[:source_page].to_i : 1
    save_backtrace
  end

  # Prepares an article for creation.
  def new
    @article = Article.new
    @article.defaults params[:category], 
                      params[:parent].present? ? params[:parent].to_i : session[:parent].to_i, 
                      params[:source].to_i
  end

  # Prepares an article defined as a child for creation.
  def new_child
    new
    render :action => :new
  end

  # Prepares an article for editing.
  def edit
    @article = Article.find_by_id(params[:id])
    if "change_status" == params[:modifier]
      render :action => :change_status
    elsif "change_category" == params[:modifier]
      render :action => :change_category
    elsif "change_image_options" == params[:modifier]
      render :action => :change_image_options
    end
  end

  # Creates new article.
  def create
    saved = false
    begin
      signature = params[:article][:signature]
      params[:article][:signature] = nil
      @article = Article.new(params[:article])
      if @article.errors.empty?
        begin
          @article.transaction do
            @article.created_by = @article.updated_by = current_user.email
            set_dates @article
            if @article.control_authorization
              @article.save!
              @article.create_audit! @article.status, @article.updated_by
              # Double-save is required in order to retrieve article.id
              @article.signature = signature
              @article.save!
              saved = true
            else
              raise ActiveRecord::Rollback, "No permission"
            end
          end
        rescue ActiveRecord::RecordInvalid => invalid
          log_warning "create", invalid
        rescue Exception => invalid
          log_error "create", invalid
        end
      end
    rescue Exception => invalid
      log_error "create", invalid
      flash[:alert] = invalid.to_s
      params[:category] = params[:article][:category]
      params[:parent] = params[:article][:parent]
      params[:source] = params[:article][:source]
      new
    end
    if saved
      notification_article
      flash[:notice] = t('action.article.created')
      redirect_to @article
    else
      render :action => :new
    end
  end

  # Updates an article.
  def update
    saved = false
    begin
      signature = params[:article][:signature]
      @comments = params[:comments]
      @article.transaction do
        @article.updated_by = current_user.email
        @article.update_attributes!(params[:article])
        if "change_image_options" == params[:modifier]
          @article.image.reprocess! unless @article.image.nil?
        end
        set_dates @article
        if @article.control_authorization
          @article.create_audit! @article.status, @article.updated_by, @comments
          @article.save!
          saved = true
        else
          raise ActiveRecord::Rollback, "No permission"
        end
      end
    rescue ActiveRecord::RecordInvalid => invalid
      log_warning "update", invalid
    rescue Exception => invalid
      log_error "update", invalid
      flash[:alert] = invalid.to_s
    end
    if saved
      notification_article true
      flash[:notice] = t('action.article.updated')
      redirect_to @article
    else
      if "change_status" == params[:modifier]
        render :action => :change_status
      elsif "change_category" == params[:modifier]
        render :action => :change_category
      elsif "change_image_options" == params[:modifier]
        render :action => :change_image_options
      else
        render :action => :edit
      end
    end
  end

  # Deletes an article.
  def destroy
    saved = false
    begin
      @article.transaction do
        @article.image = nil
        @article.document = nil
        @article.save
        @article.destroy
        saved = true
      end
    rescue Exception => invalid
      log_error "destroy", invalid
      flash[:alert] = invalid.to_s
    end
    flash[:notice] = t('action.article.deleted') if saved
    prepare_index
    render :action => :index
  end

  # Returns the list of headings based on a search string.
  def headings
    render :json => Article.all_headings(params[:search])
  end

  # Returns the list of signatures based on a search string.
  def signatures
    render :json => Article.all_signatures(params[:search])
  end

private

  # Prepares data for display in the index page.  
  def prepare_index
    @uploaded_image = Article.new
    @uploaded_document = Article.new
    if params[:log]
      @articles = Article.find_by_criteria_log({}, @page)
      @pages = Article.count_pages_by_criteria({})
    else
      @articles = Article.find_by_criteria({:status => params[:status], 
                                            :category => params[:category],
                                            :zoom => params[:zoom], 
                                            :zoom_video => params[:zoom_video], 
                                            :parent => params[:parent], 
                                            :source => params[:source], 
                                            :search => params[:search],
                                            :any_date => true}, @page)
      @pages = Article.count_pages_by_criteria({:status => params[:status], 
                                                :category => params[:category], 
                                                :zoom => params[:zoom], 
                                                :zoom_video => params[:zoom_video], 
                                                :parent => params[:parent], 
                                                :source => params[:source], 
                                                :search => params[:search],
                                                :any_date => true})
    end
    @categories_new = Article.find_by_status_group_by_category Article::NEW
    @categories_rework = Article.find_by_status_group_by_category Article::REWORK
    @categories_reviewed = Article.find_by_status_group_by_category Article::REVIEWED
    @categories_online = Article.find_by_status_group_by_category Article::ONLINE
    @zoom_new = Article.count_by_status_zoom Article::NEW
    @zoom_rework = Article.count_by_status_zoom Article::REWORK
    @zoom_reviewed = Article.count_by_status_zoom Article::REVIEWED
    @zoom_online = Article.count_by_status_zoom Article::ONLINE
    @zoom_video_new = Article.count_by_status_zoom_video Article::NEW
    @zoom_video_rework = Article.count_by_status_zoom_video Article::REWORK
    @zoom_video_reviewed = Article.count_by_status_zoom_video Article::REVIEWED
    @zoom_video_online = Article.count_by_status_zoom_video Article::ONLINE
    session[:category] = params[:category]
    session[:status] = params[:status]
    session[:parent] = params[:parent]
    session[:source] = params[:source]
    session[:search] = params[:search]
    session[:zoom] = params[:zoom]
    session[:zoom_video] = params[:zoom_video]
    session[:log] = params[:log]
    session[:page] = @page
  end

  def load_side_data
    @folders = Article::folders
    @sources = Article::sources
    @categories = Article::categories
  end

  # Controls current user is allowed to save an article of a given category.
  def pre_control_authorization
    message = Article::pre_control_authorization(current_user.email, params[:category], params[:source].to_i)
    if message.present?
      flash.now[:notice] = message.html_safe
      prepare_index
      render :action => :index
    end
  end

  # Sets dates based on parameters.
  def set_dates(article)
    error = 0
    if params[:published_at].present?
      begin
        article.published_at = Date.strptime(params[:published_at], t('date.formats.default'))
      rescue
        error += 1
        article.errors.add(:published_at, I18n.t('activerecord.errors.messages.bad_format'))
      end
    end
    if params[:expired_at].present?
      begin
        article.expired_at = Date.strptime(params[:expired_at], t('date.formats.default'))
      rescue
        error += 1
        article.errors.add(:expired_at, I18n.t('activerecord.errors.messages.bad_format'))
      end
    end
    raise(ActiveRecord::Rollback, "Bad format") if error > 0
  end

  # Selects article based on its id.
  def find
    @article = Article.find_by_id(params[:id])
    flash[:notice] = t('general.no_data') if @article.nil?
    redirect_to({:controller => :articles, :action => :index}) if @article.nil?
  end

  # Notifies an article has been created or updated.  
  def notification_article(update = false)
    return if @article.nil? or @article.draft
    @article.email_notification(current_user.email,
                                url_for(:controller => :accueil,
                                        :action => :index,
                                        :only_path => false),
                                url_for(:controller => :articles, 
                                        :action => :show, 
                                        :id => @article.id,
                                        :only_path => false),
                                (@article.status == Article::ONLINE and
                                @article.category_option?(:controller) and
                                @article.category_option?(:action)) ?
                                  url_for(:controller => @article.category_option(:controller),
                                          :action => @article.category_option(:action),
                                          :uri => @article.uri,
                                          :only_path => false) : nil,
                                update,
                                @comments)
  end
end