# Appcircle iOS Build Version Increment

This component sets the Info.plist's build version (CFBundleVersion) to number count of builds inside Appcircle.

Required Input Variables

- `$INFO_PLIST_PATH`: Specifies full path to the Info.plist file. Defaults to `./Info.plist`. You must inclulde the filename (Info.plist) here.

Optional Input Variables

- `$AC_REPOSITORY_DIR`: Specifies the cloned repository directory.
