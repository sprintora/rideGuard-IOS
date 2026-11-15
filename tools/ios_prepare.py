"""Prepares the ios/ folder for the RideGuard driver build (run in CI on macOS).

* Info.plist: permission texts + background modes (location, Bluetooth)
* Podfile: iOS 15 minimum (Firebase) + permission_handler feature flags

If ios/Podfile does not exist yet (Flutter only generates it on a Mac during
the first iOS build), it is generated first with:
    flutter pub get
    flutter build ios --config-only --no-codesign
"""
import plistlib, re, subprocess, sys, pathlib

plist_path = pathlib.Path('ios/Runner/Info.plist')
podfile = pathlib.Path('ios/Podfile')

# ---------------------------------------------------------------- Podfile
# Flutter generates the Podfile on the first iOS build, so create it if missing.
if not podfile.exists():
    print('ios/Podfile not found - generating it with Flutter...')
    try:
        subprocess.run(['flutter', 'pub', 'get'], check=True)
        subprocess.run(
            ['flutter', 'build', 'ios', '--config-only', '--no-codesign'],
            check=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError) as e:
        sys.exit(f'Could not generate ios/Podfile automatically: {e}')

if not podfile.exists():
    sys.exit('ios/Podfile still not found after running Flutter')

# ------------------------------------------------------------- Info.plist
with plist_path.open('rb') as f:
    plist = plistlib.load(f)

plist['CFBundleDisplayName'] = 'RideGuard'
plist['NSLocationWhenInUseUsageDescription'] = (
    'RideGuard uses your location to show and record the bus position during a trip.')
plist['NSLocationAlwaysAndWhenInUseUsageDescription'] = (
    'RideGuard keeps recording the bus position during a trip, even when the screen is locked.')
plist['NSLocationAlwaysUsageDescription'] = plist['NSLocationAlwaysAndWhenInUseUsageDescription']
plist['NSBluetoothAlwaysUsageDescription'] = (
    'RideGuard connects to the Ride Reader card unit on the bus over Bluetooth.')
plist['NSBluetoothPeripheralUsageDescription'] = plist['NSBluetoothAlwaysUsageDescription']
plist['UIBackgroundModes'] = ['location', 'bluetooth-central']

with plist_path.open('wb') as f:
    plistlib.dump(plist, f)

# ----------------------------------------------------------------- Podfile
text = podfile.read_text()

# minimum iOS version (Firebase iOS SDK 12 needs 15.0)
if re.search(r"^\s*#?\s*platform :ios,.*$", text, re.M):
    text = re.sub(r"^\s*#?\s*platform :ios,.*$", "platform :ios, '15.0'", text, count=1, flags=re.M)
else:
    text = "platform :ios, '15.0'\n" + text

marker = 'flutter_additional_ios_build_settings(target)'
if 'PERMISSION_LOCATION_ALWAYS' not in text:
    if marker not in text:
        sys.exit('Podfile post_install marker not found')
    block = marker + """
    target.build_configurations.each do |config|
      config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= [
        '$(inherited)',
        'PERMISSION_LOCATION=1',
        'PERMISSION_LOCATION_WHENINUSE=1',
        'PERMISSION_LOCATION_ALWAYS=1',
        'PERMISSION_BLUETOOTH=1',
        'PERMISSION_NOTIFICATIONS=1',
      ]
    end"""
    text = text.replace(marker, block, 1)
podfile.write_text(text)
print('ios/ prepared')
