# Replacing the bundled libgphoto2

Film Tether dynamically links libgphoto2, which is under the LGPL 2.1 or later. If you want to run the app against your own build of libgphoto2 instead of the copy that ships in the bundle, here is how to swap it in.

libgphoto2 source is at https://github.com/gphoto/libgphoto2.

## What's in the bundle

```
Film Tether.app/
  Contents/
    Frameworks/
      libgphoto2.*.dylib
      libgphoto2_port.*.dylib
    Resources/
      camlibs/    (camera drivers, loaded at runtime)
      iolibs/     (USB transport, loaded at runtime)
```

To see the bundled version:

```bash
otool -L "Film Tether.app/Contents/Frameworks/libgphoto2.6.dylib" | head -5
```

## Build libgphoto2 from source

```bash
git clone https://github.com/gphoto/libgphoto2.git
cd libgphoto2
autoreconf --install --symlink
./configure --prefix=/tmp/my-libgphoto2 --disable-docs
make -j8
make install
```

## Swap it into the app

```bash
APP="/Applications/Film Tether.app"   # adjust to your install location

# back up the originals first
cp -a "$APP/Contents/Frameworks" "$APP/Contents/Frameworks.bak"
cp -a "$APP/Contents/Resources/camlibs" "$APP/Contents/Resources/camlibs.bak"

# swap the top-level dylibs
cp /tmp/my-libgphoto2/lib/libgphoto2.*.dylib "$APP/Contents/Frameworks/"
cp /tmp/my-libgphoto2/lib/libgphoto2_port.*.dylib "$APP/Contents/Frameworks/"

# swap the camlibs and iolibs
rm -rf "$APP/Contents/Resources/camlibs" "$APP/Contents/Resources/iolibs"
cp -R /tmp/my-libgphoto2/lib/libgphoto2/*/. "$APP/Contents/Resources/camlibs/"
cp -R /tmp/my-libgphoto2/lib/libgphoto2_port/*/. "$APP/Contents/Resources/iolibs/"
```

If your build uses absolute install names, point them back at `@rpath`:

```bash
install_name_tool -id "@rpath/libgphoto2.6.dylib" "$APP/Contents/Frameworks/libgphoto2.6.dylib"
install_name_tool -id "@rpath/libgphoto2_port.12.dylib" "$APP/Contents/Frameworks/libgphoto2_port.12.dylib"
install_name_tool -change "/tmp/my-libgphoto2/lib/libgphoto2_port.12.dylib" "@rpath/libgphoto2_port.12.dylib" "$APP/Contents/Frameworks/libgphoto2.6.dylib"
```

Replacing the dylibs invalidates the code signature, so re-sign afterward:

```bash
codesign --force --deep --sign - "$APP"          # ad-hoc
# or with your own Developer ID:
codesign --force --deep --sign "Developer ID Application: Your Name (TEAMID)" "$APP"
```

Then open the app and plug in the camera.
