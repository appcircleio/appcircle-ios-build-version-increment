require 'open3'
require 'pathname'
require 'xcodeproj'
require 'json'
require 'net/http'
require 'plist'
require 'colored'

def env_has_key(key)
  value = ENV[key]
  if !value.nil? && value != ''
    return value.start_with?('$') ? ENV[value[1..-1]] : value
  else
    abort("Missing #{key}.")
  end
end

def get_env(key)
  value = ENV[key]
  if !value.nil? && value != ''
   return value.start_with?('$') ? ENV[value[1..-1]] : value
  else
    return nil
  end
end

# Get the .xcodeproj file path
def xcode_project_file
  repository_path = env_has_key('AC_REPOSITORY_DIR')
  project_path = env_has_key('AC_PROJECT_PATH')
  project_path = (Pathname.new repository_path).join(Pathname.new(project_path))
  puts "Project path: #{project_path}"
  project_directory = File.dirname(project_path)
  puts "Project directory: #{project_directory}"
  if File.extname(project_path) == '.xcworkspace'
    Dir[File.join(project_directory, '*.xcodeproj')][0]
  else
    project_path
  end
end

def get_value_from_build_settings!(target, variable, configuration = nil)
    target.build_configurations.each do |config|
        if configuration.nil? || config.name == configuration
          value = config.resolve_build_setting(variable)
          return value if value
        end
    end
end

def runnable_target?(target)
  product_reference = target.product_reference
  return false unless product_reference
  product_reference.path.end_with?('.app', '.appex')
end

def update_target(params,target,key,value,variable)
  # Update Xcode config if Xcode is generating the plist
  target.build_configurations.each do |config|
    if config.build_settings['GENERATE_INFOPLIST_FILE'] == 'YES'
      config.build_settings[variable] = value
    end
  end
  # If plist doesn't exist, update target with Xcode config
  info_plist_path = get_plist(params,target)
  if info_plist_path.nil?
    puts "Warning: No plist found for target '#{target.name}'. Updating the Xcode project variable.".yellow
    target.build_configurations.each do |config|
      config.build_settings[variable] = value
    end
    return
  end
  
  plist = Xcodeproj::Plist.read_from_path(info_plist_path)
    
  build_number = plist[key]  
  if build_number.nil?
    target.build_configurations.each do |config|
      config.build_settings[variable] = value
    end
    return
  end

  # if the build number comes from a settings such as $MARKETING_VERSION or ${MARKETING_VERSION}
  if build_number =~ /\$\(([\w\-]+)\)/ || build_number =~ /\$\{([\w\-]+)\}/
    puts "Update via config #{key}: #{build_number}"
    target.build_configurations.each do |config|
      config.build_settings[$1] = value
    end

  else
    puts "Directly updating 'Info.plist' with the value: '#{build_number}'.".blue
    plist[key] = value
    Xcodeproj::Plist.write_to_path(plist, info_plist_path)
  end

end

def increment_key(params,key,value,variable)
    project = Xcodeproj::Project.open(params[:xcodeproj])

    if params[:targets].nil? || params[:targets].empty?
      # We will use all runnable apps and extensions.
      puts "Selecting only apps and extensions"
      project.native_targets.each do |target|
        if runnable_target?(target)
          puts "Target: #{target.name}"
          # Update mechanism
          update_target(params,target,key,value,variable)
          else
            puts "Skipping target: #{target.name}"
        end
       
      end
  
    else
      # Select the targets by name
      puts "Selecting target(s) by name"
      allowed_targets = params[:targets].split('|')
      project.native_targets.each do |target|
        if allowed_targets.include?(target.name)
          puts "Target: #{target.name}"
            # Update mechanism
            update_target(params,target,key,value,variable)
          else
            puts "Skipping target: #{target.name}"
        end
       
      end

    end
    project.save
end

def get_plist(params,target)
  scheme_name = params[:scheme]
  scheme_file = File.join(params[:xcodeproj], 'xcshareddata', 'xcschemes', "#{scheme_name}.xcscheme")
  if File.exist?(scheme_file) and params[:configuration].nil?
    scheme = Xcodeproj::XCScheme.new(scheme_file)
    puts "Archiving configuration: #{scheme.archive_action.build_configuration}"
    params[:configuration] = scheme.archive_action.build_configuration
  end

  if params[:configuration]
    build_config = target.build_configurations.detect { |c| c.name == params[:configuration] }
  else
    abort("Error: Configuration not found. Please ensure the scheme is shared and the correct configuration is specified.".red)
  end
  repository_path = env_has_key('AC_REPOSITORY_DIR')
  project_path = env_has_key('AC_PROJECT_PATH')
  project_path = (Pathname.new repository_path).join(Pathname.new(project_path))
  project_directory = File.dirname(project_path)
  info_plist = build_config.build_settings["INFOPLIST_FILE"]
  if info_plist.nil?
    puts "Warning: The 'Info.plist' file is not specified in the build settings for target '#{target.name}'.".yellow
    return nil
  end
  info_plist_path = (Pathname.new project_directory).join(Pathname.new(info_plist))
  return info_plist_path
end

def appstore_version
  bundle_id = env_has_key('AC_BUNDLE_ID')
  country = get_env('AC_APPSTORE_COUNTRY')
  uri = if country
          URI("http://itunes.apple.com/lookup?bundleId=#{bundle_id}&country=#{country}")
        else
          URI("http://itunes.apple.com/lookup?bundleId=#{bundle_id}")
        end
  response = Net::HTTP.get_response(uri)
  abort("Error: Received an unexpected status code from the iTunes Search API for bundle ID '#{bundle_id}' and country '#{country}'.".red) unless response.is_a?(Net::HTTPSuccess)
  response_body = JSON.parse(response.body)
  response_body['results'][0]['version']
end

def get_build_number(params, source)
  case source
  when 'xcode'
    get_value_from_plist(params, 'CFBundleVersion','CURRENT_PROJECT_VERSION')
  when 'env'
    env_has_key('AC_IOS_BUILD_NUMBER')
  end
end

def get_version_number(params, source)
  case source
  when 'xcode'
    get_value_from_plist(params, 'CFBundleShortVersionString','MARKETING_VERSION')
  when 'appstore'
    appstore_version
  when 'env'
    env_has_key('AC_IOS_VERSION_NUMBER')
  end
end

def get_value_from_plist(params,key,variable)
  project = Xcodeproj::Project.open(params[:xcodeproj])

  target = project.targets.detect do |t|
    t.is_a?(Xcodeproj::Project::Object::PBXNativeTarget) &&
      t.product_type == 'com.apple.product-type.application'
  end

  info_plist_path = get_plist(params,target)
  if info_plist_path.nil?
    puts "Warning: Unable to read 'Info.plist' file. Attempting to retrieve value from Xcode variable '#{variable}'.".yellow
    build_number = get_value_from_build_settings!(target, variable, params[:configuration]) || get_value_from_build_settings!(project, variable, params[:configuration])
    return build_number
  end

  plist = Xcodeproj::Plist.read_from_path(info_plist_path)

  build_number = plist[key]
  if build_number =~ /\$\(([\w\-]+)\)/
    build_number = get_value_from_build_settings!(target, $1,  params[:configuration]) || get_value_from_build_settings!(project, $1,  params[:configuration])  
  elsif build_number =~ /\$\{([\w\-]+)\}/
    build_number = get_value_from_build_settings!(target, $1, params[:configuration]) || get_value_from_build_settings!(project, $1, params[:configuration])
  elsif build_number.nil? && variable
    puts "Warning: No value for '#{key}' was found in 'Info.plist'. Attempting to retrieve the value from the Xcode variable '#{variable}'.".yellow
    build_number = get_value_from_build_settings!(target, variable, params[:configuration]) || get_value_from_build_settings!(project, variable, params[:configuration])
  end
  build_number
end

def calculate_build_number(current_build_number, offset)
  build_array = current_build_number.split('.').map(&:to_i)
  build_array[-1] = build_array[-1] + offset.to_i
  build_array.join('.')
end

def calculate_version_number(current_version, strategy, omit_zero,offset)
  version_array = current_version.split('.').map(&:to_i)
  case strategy
  when 'patch'
    version_array[2] = (version_array[2] || 0) +  offset.to_i
  when 'minor'
    version_array[1] = (version_array[1] || 0) +  offset.to_i
    version_array[2] = version_array[2] = 0
  when 'major'
    version_array[0] = (version_array[0] || 0) +  offset.to_i
    version_array[1] = version_array[1] = 0
    version_array[1] = version_array[2] = 0
  end

  if omit_zero && version_array[2] == 0
    version_array.pop
  end
  version_array.join('.')
end

scheme = env_has_key('AC_SCHEME')
params = {}
params[:configuration] = get_env('AC_IOS_CONFIGURATION_NAME')
params[:xcodeproj] = xcode_project_file
params[:scheme] = scheme
params[:targets] = get_env("AC_TARGETS")

build_offset = get_env('AC_BUILD_OFFSET') || 0
version_offset =  get_env('AC_VERSION_OFFSET') || 0

version_strategy = get_env('AC_VERSION_STRATEGY') || 'keep' # "keep"  major,minor, patch
build_number_source = get_env('AC_BUILD_NUMBER_SOURCE') # xcode, env
version_number_source =  get_env('AC_VERSION_NUMBER_SOURCE') # xcode, appstore, env
ac_env_build_number = get_env('AC_IOS_BUILD_NUMBER')

omit_zero = get_env('AC_OMIT_ZERO_PATCH_VERSION') == 'true' ? true : false

begin
  if version_number_source.nil? && build_number_source.nil?
    puts "Error: No version or build number source specified. Please set the version or build number increment strategy in the Build Configuration.".red
    puts "Skipping this step..".red
    exit 0
  else
    
    if build_number_source.nil?
      puts "Warning: No build number source specified. Skipping the build number update. If you want to update the build number, please set it in the Build Configuration.".yellow.bold
    else
      xcode_build_number = get_build_number(params, 'xcode')
      puts "Project Build Number: #{xcode_build_number}"
      puts "Appcircle Build Number: #{ac_env_build_number}" if build_number_source == 'env'
      next_build_number = xcode_build_number

      puts "Updating the Build number.".blue
      current_build_number = build_number_source == 'xcode' ? xcode_build_number : get_build_number(params, build_number_source)
      next_build_number = calculate_build_number(current_build_number, build_offset)
      puts "Next build: #{next_build_number} Reason -> Source: #{build_number_source} offset: #{build_offset}"
      increment_key(params, 'CFBundleVersion', next_build_number,'CURRENT_PROJECT_VERSION')
      puts "Build number updated to: #{next_build_number}".blue
    end 

    if version_number_source.nil?
      puts "Warning: No version number source specified. Skipping the version number update. If you want to update the version number, please set it in the Build Configuration.".yellow.bold
    else
      xcode_version_number = get_version_number(params, 'xcode')
      puts "Project Version Number: #{xcode_version_number}"
      next_version_number = xcode_version_number

      puts "Updating the Version number.".blue
      current_version_number = version_number_source == 'xcode' ? xcode_version_number : get_version_number(params, version_number_source)
      if version_strategy == 'keep'
        next_version_number = current_version_number
      else
        next_version_number = calculate_version_number(current_version_number, version_strategy, omit_zero, version_offset)
      end
      puts "Next version: #{next_version_number}  Reason -> Source: #{version_number_source} Strategy: #{version_strategy} Omit zero: #{omit_zero} Offset: #{version_offset}"
      increment_key(params, 'CFBundleShortVersionString', next_version_number,'MARKETING_VERSION')
      puts "Version number updated to: #{next_version_number}".blue
    end


    open(ENV['AC_ENV_FILE_PATH'], 'a') { |f|
      f.puts "AC_IOS_NEW_BUILD_NUMBER=#{next_build_number}" if next_build_number
      f.puts "AC_IOS_NEW_VERSION_NUMBER=#{next_version_number}" if next_version_number
    }

    puts "The process for Build and Version number increment has been completed successfully.".green.bold

    exit 0
  end
rescue StandardError => e
  abort("Error: Your project is not compatible for version upgrade. Project is not updated. \nDetails: #{e} ".red)
  
end
