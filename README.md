# Appcircle iOS Version and Build Number Increment

This component bumps the version `$(MARKETING_VERSION)` and the build numbers `$(CURRENT_PROJECT_VERSION)` according to the given strategies.

## Required Input Variables

- `$AC_REPOSITORY_DIR`: Specifies the cloned repository directory.
- `$AC_PROJECT_PATH`: Specifies Xcode project or workspace file.
- `$AC_SCHEME`: Xcode Scheme
- `$AC_BUILD_NUMBER_SOURCE`: Build number source type(env,xcode)
- `$AC_IOS_BUILD_NUMBER`: Build number to set. If `$AC_BUILD_NUMBER_SOURCE` is set to `xcode`, this variable will be read from the project
- `$AC_BUILD_OFFSET`: The number to be added or subtracted from the  `$AC_IOS_BUILD_NUMBER` Negative values can be written such as `-10`. Default is `1`
- `$AC_VERSION_NUMBER_SOURCE`: Version number source type(env,xcode,appstore)
- `$AC_IOS_VERSION_NUMBER`: Version number to set. If `$AC_VERSION_NUMBER_SOURCE` is set to `xcode`, this variable will be read from the project
- `$AC_VERSION_STRATEGY`: Version Increment Strategy major, minor, patch or keep. Default is `keep`
- `$AC_VERSION_OFFSET`: The number to be added or subtracted from the  `$AC_IOS_VERSION_NUMBER` Negative values can be written such as `-10`. Default is `0`

## Optional Input Variables

- `$AC_IOS_CONFIGURATION_NAME`: Xcode Configuration to extract build number and version number. Default is the first target's Archive configuration
- `$AC_TARGETS`: Name of the targets to update. You can separate multiple targets by comma. If you don't specify any target, all runnable targets will be updated.
- `$AC_OMIT_ZERO_PATCH_VERSION`: If true omits zero in patch version(so 42.10.0 will become 42.10 and 42.10.1 will remain 42.10.1), default is `false`
- `$AC_BUNDLE_ID`: If the build number source is `appstore`, this variable should have the bundle id of your application. Ex. `com.example.myapp`
- `$AC_APPSTORE_COUNTRY`: If the build Number source is `appstore` and the app is only available in some countries, set the country code. Ex. `us`


## Output Variables

- `$AC_IOS_NEW_BUILD_NUMBER`: Changed build number
- `$AC_IOS_NEW_VERSION_NUMBER`: Changed version number

## Credits

[Versioning fastlane Plugin](https://github.com/SiarheiFedartsou/fastlane-plugin-versioning)

## Running tests

Requires the [RSpec](https://rspec.info) gem plus the `xcodeproj`, `plist` and `colored` gems the
step itself uses, and the Ruby standard library (Coverage, Open3). No Gemfile or Bundler needed.

```bash
ruby test/test_main.rb
```

The suite never touches the network or the Xcode toolchain. `appstore_version` runs against a
stubbed `Net::HTTP` response, and the `increment_key` / `get_value_from_plist` tests build a real
throwaway `.xcodeproj` inside a temp dir with the pure-Ruby `xcodeproj` gem. The `ENV` validation
and end-to-end cases run `main.rb` in a subprocess with a fully controlled environment. A coverage
report for `main.rb` is printed at the end of each run.
