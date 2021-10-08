require 'open3'
require 'pathname'

plist_path = ENV["INFO_PLIST_PATH"] || "./Info.plist"
repository_path = ENV["AC_REPOSITORY_DIR"]
build_number = ENV["AC_BUILD_NUMBER"]

plist_dir_file = repository_path ? (Pathname.new repository_path).join(Pathname.new(plist_path)) : File.dirname(plist_path)

unless File.exist?(plist_dir_file)
    puts "Plist file does not exist on #{plist_dir_file}."
    exit 0
end

def runCommand(command)
    puts "@@[command] #{command}"
    unless system(command)
        exit $?.exitstatus
    end
end

runCommand("set -e")
runCommand("set -x")

command = "/usr/libexec/PlistBuddy -c "
command += "\"Set :CFBundleVersion "
command += "#{build_number}\" "
command += "\"#{plist_dir_file}\""
runCommand(command)

exit 0
