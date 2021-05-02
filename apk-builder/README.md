Modified from https://source.winehq.org/git/tools.git/tree/1528f95b83cd13e118e2609cfc3752063ef22ae7:/packaging/android

## Dependencies (Ubuntu)

```sh
sudo apt-get install wget git flex bison automake libtool autoconf build-essential unzip python-is-python2 python3 groff-base pkg-config libfreetype6-dev openjdk-8-jdk-headless librsvg2-bin cmake
```

## Building

Run `./build-apks 6.0-rc6` to build an APK with Wine `6.0-rc6`.
Newer versions are less likely to work.
