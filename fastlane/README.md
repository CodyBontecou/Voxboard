fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

### builds

```sh
[bundle exec] fastlane builds
```

List recent builds and processing state

----


## iOS

### ios info

```sh
[bundle exec] fastlane ios info
```

Show current app info on App Store Connect

### ios upload_metadata

```sh
[bundle exec] fastlane ios upload_metadata
```

Upload metadata only

### ios upload_screenshots

```sh
[bundle exec] fastlane ios upload_screenshots
```

Upload screenshots only

### ios upload_all

```sh
[bundle exec] fastlane ios upload_all
```

Upload metadata + screenshots

### ios submit

```sh
[bundle exec] fastlane ios submit
```

Submit for review (uploads metadata + screenshots first)

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
