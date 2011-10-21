require 'thor'
require 'yaml'
require 'abbrev'
require 'base64'
require 'fileutils'
require 'json'
require 'fssm'
require 'sass'

module ShopifyTheme
  class Cli < Thor

    include Thor::Actions

    BINARY_EXTENSIONS = %w(png gif jpg jpeg eot svg ttf woff swf)
    SASS_EXTENSION = /\.s[ca]ss?$/
    IGNORE = %w(config.yml)
    ICON = File.dirname(__FILE__) + '/images/shopify.png'

    tasks.keys.abbrev.each do |shortcut, command|
      map shortcut => command.to_sym
    end

    desc "configure API_KEY PASSWORD STORE_URL", "generate a config file for the store to connect to"
    def configure(api_key=nil, password=nil, store=nil)
      config = {:api_key => api_key, :password => password, :store => store}
      create_file('config.yml', config.to_yaml)
	    say("Generated config.yml", :green)
	    notify "config.yml", :title => 'Config Generated', :icon => ICON
    end

    desc "download FILE", "download the shops current theme assets"
    method_option :quiet, :type => :boolean, :default => false
    def download(*keys)
      assets = keys.empty? ? ShopifyParty.asset_list : keys

      assets.each do |asset|
        download_asset(asset)
        say("Downloaded: #{asset}", :green) unless options['quiet']
      end
      say("Done.", :green) unless options['quiet']
    end

    desc "upload FILE", "upload all theme assets to shop"
    method_option :quiet, :type => :boolean, :default => false
    def upload(*keys)
      assets = keys.empty? ? local_assets_list : keys
      assets.each do |asset|
        send_asset(asset, options['quiet'])
      end
      say("Done.", :green) unless options['quiet']
    end

    desc "replace FILE", "completely replace shop theme assets with local theme assets"
    method_option :quiet, :type => :boolean, :default => true
    def replace(*keys)
	    say("Are you sure you want to completely replace your shop theme assets? This is not undoable.", :yellow)
	    if ask("Continue? (Y/N): ") == "Y"
		    remote_assets = keys.empty? ? ShopifyParty.asset_list : keys
	      remote_assets.each do |asset|
	        delete_asset(asset, options['quiet'])
	      end
	      local_assets = keys.empty? ? local_assets_list : keys
	      local_assets.each do |asset|
	        send_asset(asset, true)
	      end
	      notify "#{remote_assets.size} Removed \n #{remote_assets.size} Uploaded", :title => 'Replaced Assets', :icon => ICON unless options['quiet']
	      say("Done.", :green) unless options['quiet']
		  end
    end

    desc "remove FILE", "remove theme asset"
    method_option :quiet, :type => :boolean, :default => false
    def remove(*keys)
      keys.each do |key|
				delete_asset(key, options['quiet'])
      end
      say("Done.", :green) unless options['quiet']
    end

    desc "watch", "upload and delete individual theme assets as they change, use the --keep_files flag to disable remote file deletion"
    method_option :quiet, :type => :boolean, :default => false
    method_option :keep_files, :type => :boolean, :default => false
    def watch
      FSSM.monitor '.' do |m|
        m.update do |base, relative|
	        if !ignored_files.include?(relative)
	          send_asset(relative, options['quiet']) if local_assets_list.include?(relative)
	        else
	          ignored_files.delete(relative)
	        end
        end
        m.create do |base, relative|
          send_asset(relative, options['quiet']) if local_assets_list.include?(relative)
        end
        if !options['keep_files']
	        m.delete do |base, relative|
						delete_asset(relative, options['quiet'])
		      end
	      end
      end
    end

    private

    def ignored_files
      @ignored_files ||= []
    end

    def local_assets_list
      Dir.glob(File.join("**", "*")).reject{ |p| File.directory?(p) || IGNORE.include?(p)}
    end

    def download_asset(key)
      asset = ShopifyParty.get_asset(key)
      if asset['value']
        # For CRLF line endings
        content = asset['value'].gsub("\r", "")
      elsif asset['attachment']
        content = Base64.decode64(asset['attachment'])
      end

      FileUtils.mkdir_p(File.dirname(key))
      File.open(key, "w") {|f| f.write content} if content
    end

    def send_asset(asset, quiet=false)
      data = {:key => asset}
      if compile_asset(asset, quiet)  
	      if (content = File.read(asset)).is_binary_data? || BINARY_EXTENSIONS.include?(File.extname(asset).gsub('.',''))
	        data.merge!(:attachment => Base64.encode64(content))
	      else
	        data.merge!(:value => content)
	      end

        response = ShopifyParty.send_asset(data)      
        if response.success?
          notify "#{asset}", :title => 'Uploaded Asset', :icon => ICON unless quiet
          say("Uploaded: #{asset}", :green) unless quiet      
        else        
          errors = response.parsed_response["errors"] if response.parsed_response
          errors = errors.collect{|(key, value)| "#{value.join(', ')}"} if errors
          notify "#{asset} \n #{errors}", :title => 'Upload Error', :icon => ICON unless quiet
          say("Upload error: #{asset} - #{errors}\n", :red)      
        end
      end   
    end

		def compile_asset(asset, quiet=false)
	    if asset =~ SASS_EXTENSION
				begin
					original_asset = asset
					sass_engine = Sass::Engine.for_file(asset,{})
					asset.gsub!(SASS_EXTENSION, '.css')
					ignored_files.push(asset)
					File.open(asset, 'w') {|f| f.write(sass_engine.render)}
					notify "#{original_asset} => #{asset}", :title => 'Rendered SASS', :icon => ICON unless quiet
					say("Rendered SASS: #{original_asset} => #{asset}", :magenta) unless quiet
					true
				rescue Sass::SyntaxError => e
					notify "#{e.sass_filename}:#{e.sass_line} \n #{e.message}", :title => 'Syntax Error', :icon => ICON unless quiet
					say("#{e.sass_filename}:#{e.sass_line} - #{e.message}", :red) unless quiet
					false
				end
		  end
		  true
		end

    def delete_asset(key, quiet=false)
			return if key =~ SASS_EXTENSION
			#if ShopifyParty.delete_asset(key).success?
      #  say("Removed: #{key}", :green) unless quiet
      #else
      #  say("Error: Could not remove #{key}", :red)
      #end
      response = ShopifyParty.delete_asset(key)      
      if response.success?
        say("Removed: #{key}", :green) unless quiet
        notify "#{key}", :title => 'Removed Asset', :icon => ICON unless quiet     
      else        
        errors = response.parsed_response["errors"] if response.parsed_response
        errors = errors.collect{|(key, value)| "#{value.join(', ')}"} if errors
        notify "#{key} \n #{errors}", :title => 'Remove Error', :icon => ICON unless quiet
        say("Error: Could not remove #{key} - #{errors}\n", :red)
      end
    end

    def notify(message, options={})
      return super if @growl_loaded
      return if @growl_tried
      begin
        require 'growl'
        self.class.send(:include, Growl)
        @growl_loaded = true
      rescue LoadError => e
        @growl_tried = true
        say("Growl not found: gem install growl to receive notifications")
      end
    end
  end
end
