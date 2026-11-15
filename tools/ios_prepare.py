"""Prepares the ios/ folder for the RideGuard driver build (run in CI on macOS).

* Info.plist: permission texts + background modes (location, Bluetooth)
* Podfile: iOS 15 minimum (Firebase) + permission_handler feature flags

If ios/Podfile does not exist, it is created first:
  1. try `flutter pub get` + `flutter build ios --config-only --no-codesign`
  2. if Flutter still did not create it, write the standard Flutter Podfile
"""
import plistlib, re, subprocess, sys, pathlib

plist_path = pathlib.Path('ios/Runner/Info.plist')
podfile = pathlib.Path('ios/Podfile')
pbxproj = pathlib.Path('ios/Runner.xcodeproj/project.pbxproj')

PODFILE_TEMPLATE = r'''# Uncomment this line to define a global platform for your project
# platform :ios, '13.0'

# CocoaPods analytics sends network stats synchronously affecting flutter build latency.
ENV['COCOAPODS_DISABLE_STATS'] = 'true'

project 'Runner', {
  'Debug' => :debug,
  'Profile' => :release,
  'Release' => :release,
}

def flutter_root
  generated_xcode_build_settings_path = File.expand_path(File.join('..', 'Flutter', 'Generated.xcconfig'), __FILE__)
  unless File.exist?(generated_xcode_build_settings_path)
    raise "#{generated_xcode_build_settings_path} must exist. If you're running pod install manually, make sure \"flutter pub get\" is executed first"
  end

  File.foreach(generated_xcode_build_settings_path) do |line|
    matches = line.match(/FLUTTER_ROOT\=(.*)/)
    return matches[1].strip if matches
  end
  raise "FLUTTER_ROOT not found in #{generated_xcode_build_settings_path}. Try deleting Generated.xcconfig, then run \"flutter pub get\""
end

require File.expand_path(File.join('packages', 'flutter_tools', 'bin', 'podhelper'), flutter_root)

flutter_ios_podfile_setup

target 'Runner' do
  use_frameworks!

  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))
__RUNNER_TESTS__end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
  end
end
'''

RUNNER_TESTS_BLOCK = '''  target 'RunnerTests' do
    inherit! :search_paths
  end
'''

# ---------------------------------------------------------------- Podfile
if not podfile.exists():
    print('ios/Podfile not found - trying to generate it with Flutter...')
    try:
        subprocess.run(['flutter', 'pub', 'get'], check=True)
        subprocess.run(
            ['flutter', 'build', 'ios', '--config-only', '--no-codesign'],
            check=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError) as e:
        print(f'Flutter could not generate the Podfile: {e}')

if not podfile.exists():
    print('Flutter did not create ios/Podfile - writing the standard one')
    has_tests = pbxproj.exists() and 'RunnerTests' in pbxproj.read_text(errors='ignore')
    podfile.write_text(
        PODFILE_TEMPLATE.replace('__RUNNER_TESTS__', RUNNER_TESTS_BLOCK if has_tests else '')
    )

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
