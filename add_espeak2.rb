require 'xcodeproj'

project_path = 'LocalAI.xcodeproj'
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'LocalAI' }

# Find the LocalAI group safely
main_group = project.main_group
project.main_group.children.each do |child|
  if child.respond_to?(:path) && child.path == 'LocalAI'
    main_group = child
    break
  elsif child.respond_to?(:name) && child.name == 'LocalAI'
    main_group = child
    break
  end
end

# Check if it already exists in resources
resources_phase = target.resources_build_phase
existing = resources_phase.files.find { |f| f.file_ref && f.file_ref.path && f.file_ref.path.include?('espeak-ng-data') }

unless existing
  # Create reference
  file_ref = main_group.new_reference('PiperAudioFiles/espeak-ng-data')
  file_ref.last_known_file_type = 'folder'
  
  # Add to resources
  resources_phase.add_file_reference(file_ref)
  project.save
  puts "Successfully added espeak-ng-data to the project."
else
  puts "espeak-ng-data is already in the project."
end
