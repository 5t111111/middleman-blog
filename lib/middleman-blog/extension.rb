require 'active_support/core_ext/time/zones'
require 'middleman-blog/blog_data'
require 'middleman-blog/blog_article'
require 'middleman-blog/helpers'

module Middleman
  class BlogExtension < Extension
    extend Forwardable

    self.supports_multiple_instances = true

    def_delegator :app, :logger

    option :name, nil, 'Unique ID for telling multiple blogs apart'
    option :prefix, nil, 'Prefix to mount the blog at (modifies permalink, sources, taglink, year_link, month_link, day_link to start with the prefix)'
    option :permalink, '/{year}/{month}/{day}/{title}.html', 'Path articles are generated at. Tokens can be omitted or duplicated, and you can use tokens defined in article frontmatter.'
    option :sources, '{year}-{month}-{day}-{title}.html', 'Pattern for matching source blog articles (no template extensions)'
    option :taglink, 'tags/{tag}.html', 'Path tag pages are generated at.'
    option :layout, 'layout', 'Article-specific layout'
    option :summary_separator, /(READMORE)/, 'Regex or string that delimits the article summary from the rest of the article.'
    option :summary_length, 250, 'Truncate summary to be <= this number of characters. Set to -1 to disable summary truncation.'
    option :summary_generator, nil, 'A block that defines how summaries are extracted. It will be passed the rendered article content, max summary length, and ellipsis string as arguments.'
    option :year_link, '/{year}.html', 'Path yearly archive pages are generated at.'
    option :month_link, '/{year}/{month}.html', 'Path monthly archive pages are generated at.'
    option :day_link, '/{year}/{month}/{day}.html', 'Path daily archive pages are generated at.'
    option :calendar_template, nil, 'Template path (no template extension) for calendar pages (year/month/day archives).'
    option :year_template, nil, 'Template path (no template extension) for yearly archive pages. Defaults to the :calendar_template.'
    option :month_template, nil, 'Template path (no template extension) for monthly archive pages. Defaults to the :calendar_template.'
    option :day_template, nil, 'Template path (no template extension) for daily archive pages. Defaults to the :calendar_template.'
    option :tag_template, nil, 'Template path (no template extension) for tag archive pages.'
    option :generate_year_pages, true, 'Whether to generate year pages.'
    option :generate_month_pages, true, 'Whether to generate month pages.'
    option :generate_day_pages, true, 'Whether to generate day pages.'
    option :generate_tag_pages, true, 'Whether to generate tag pages.'
    option :paginate, false, 'Whether to paginate lists of articles'
    option :per_page, 10, 'Number of articles per page when paginating'
    option :page_link, 'page/{num}', 'Path to append for additional pages when paginating'
    option :publish_future_dated, false, 'Whether articles with a date in the future should be considered published'
    option :custom_collections, {}, 'Hash of custom frontmatter properties to collect articles on and their options (link, template)'
    option :preserve_locale, false, 'Use the global Middleman I18n.locale instead of the lang in the article\'s frontmatter'
    option :new_article_template, File.expand_path('../commands/article.tt', __FILE__), 'Path (relative to project root) to an ERb template that will be used to generate new articles from the "middleman article" command.'
    option :default_extension, '.markdown', 'Default template extension for articles (used by "middleman article")'

    # @return [BlogData] blog data for this blog, which has all information about the blog articles
    attr_reader :data

    # @return [Symbol] the name of this blog (autogenerated if not provided).
    attr_reader :name

    # @return [TagPages] tag page handler for this blog
    attr_reader :tag_pages

    # @return [CalendarPages] calendar page handler for this blog
    attr_reader :calendar_pages

    # @return [Paginator] pagination handler for this blog
    attr_reader :paginator

    # @return [Hash<CustomPages>] custom pages handlers for this blog, indexed by property name
    attr_reader :custom_pages

    # Helpers for use within templates and layouts.
    self.defined_helpers = [ Middleman::Blog::Helpers ]

    def initialize(app, options_hash={}, &block)
      super

      @custom_pages = {}

      # NAME is the name of this particular blog, and how you reference it from #blog_controller or frontmatter.
      @name = options.name.to_sym if options.name

      # Allow one setting to set all the calendar templates
      if options.calendar_template
        options.year_template  ||= options.calendar_template
        options.month_template ||= options.calendar_template
        options.day_template   ||= options.calendar_template
      end

      # If "prefix" option is specified, all other paths are relative to it.
      if options.prefix
        options.prefix = "/#{options.prefix}" unless options.prefix.start_with? '/'
        options.permalink = File.join(options.prefix, options.permalink)
        options.sources = File.join(options.prefix, options.sources)
        options.taglink = File.join(options.prefix, options.taglink)
        options.year_link = File.join(options.prefix, options.year_link)
        options.month_link = File.join(options.prefix, options.month_link)
        options.day_link = File.join(options.prefix, options.day_link)

        options.custom_collections.each do |key, opts|
          opts[:link] = File.join(options.prefix, opts[:link])
        end
      end
    end

    def after_configuration
      @name ||= :"blog#{::Middleman::Blog.instances.keys.length}"

      # TODO: break up into private methods?

      @app.ignore(options.calendar_template) if options.calendar_template
      @app.ignore(options.year_template) if options.year_template
      @app.ignore(options.month_template) if options.month_template
      @app.ignore(options.day_template) if options.day_template
      @app.ignore options.tag_template if options.tag_template

      ::Middleman::Blog.instances[@name] = self

      # Make sure ActiveSupport's TimeZone stuff has something to work with,
      # allowing people to set their desired time zone via Time.zone or
      # set :time_zone
      Time.zone = app.config[:time_zone] if app.config[:time_zone]
      time_zone = Time.zone || 'UTC'
      zone_default = Time.find_zone!(time_zone)
      unless zone_default
        raise 'Value assigned to time_zone not recognized.'
      end
      Time.zone_default = zone_default

      # Initialize blog with options
      @data = Blog::BlogData.new(@app, self, options)

      @app.sitemap.register_resource_list_manipulator(:"blog_#{name}_articles", @data)

      if options.tag_template
        @app.ignore options.tag_template

        require 'middleman-blog/tag_pages'
        @tag_pages = Blog::TagPages.new(@app, self)
        @app.sitemap.register_resource_list_manipulator(:"blog_#{name}_tags", @tag_pages)
      end

      if options.year_template || options.month_template || options.day_template
        require 'middleman-blog/calendar_pages'
        @calendar_pages = Blog::CalendarPages.new(@app, self)
        @app.sitemap.register_resource_list_manipulator(:"blog_#{name}_calendar", @calendar_pages)
      end

      if options.custom_collections
        require 'middleman-blog/custom_pages'
        register_custom_pages
      end

      if options.paginate
        require 'middleman-blog/paginator'
        @paginator = Blog::Paginator.new(@app, self)
        @app.sitemap.register_resource_list_manipulator(:"blog_#{name}_paginate", @paginator)
      end

      logger.info "== Blog Sources: #{options.sources} (:prefix + :sources)"
    end

    private

    # Register any custom page collections that may be set in the config
    #
    # A custom resource list manipulator will be generated for each key in the
    # custom collections hash.
    #
    # The following will collect posts on the "category" frontmatter property:
    #   ```
    #   activate :blog do |blog|
    #     blog.custom_collections = {
    #       category: {
    #         link: "/categories/:category.html",
    #         template: "/category.html"
    #       }
    #     }
    #   end
    #   ```
    #
    # Category pages in the example above will use the category.html as a template file
    # and it will be ignored when building.
    def register_custom_pages
      options.custom_collections.each do |property, options|
        @app.ignore options[:template]

        @custom_pages[property] = Blog::CustomPages.new(property, @app, self, options)
        @app.sitemap.register_resource_list_manipulator(:"blog_#{name}_#{property}", @custom_pages[property])

        Blog::Helpers.generate_custom_helper(property)
      end
    end
  end
end
