require 'xcodeproj'
project_path = 'LocalAI.xcodeproj'
project = Xcodeproj::Project.open(project_path)
project.targets.each do |target|
  target.build_configurations.each do |config|
    config.build_settings['SWIFT_OBJC_INTEROP_MODE'] = 'objcxx'
  end
end
project.save
puts "Successfully enabled C++ / Objective-C++ Interoperability for all targets."
